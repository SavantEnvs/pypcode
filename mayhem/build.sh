#!/usr/bin/env bash
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX MAYHEM_JOBS

cd "$SRC"

TEST_VENV=/mayhem/test-venv
FUZZ_VENV=/mayhem/fuzz-venv

# ---------------------------------------------------------------------------
# Offline wheel cache (SPEC §6.5 — air-gapped, re-runnable build).
#
# pip IS a package manager, so the same rule that covers FetchContent/conan/vcpkg applies: every
# distribution this build needs is pre-fetched ONCE into an in-image wheelhouse, and every later
# `pip install` resolves from it with --no-index. The wheelhouse deliberately lives OUTSIDE the
# source tree because rlenv's patch grader runs `git clean -ffdX` on /mayhem
# before every graded build and pypcode's .gitignore covers `*.so`/`*.sla`/`build/`/`*.egg-info/`
# — a cache under /mayhem would be deleted and the re-build would need the network again
# (SPEC §6.2 item 16).
# ---------------------------------------------------------------------------
# /opt/wheelhouse is created (and chowned to the build user) by mayhem/Dockerfile. Fall back to the
# passwd home -- NOT $HOME, which docker leaves pointing at /root across `USER mayhem` -- then /tmp,
# so build.sh still works when run outside the commit image.
WHEELHOUSE="${WHEELHOUSE:-/opt/wheelhouse}"
if ! mkdir -p "$WHEELHOUSE" 2>/dev/null || [ ! -w "$WHEELHOUSE" ]; then
  _h="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
  [ -n "$_h" ] && [ -w "$_h" ] || _h=/tmp
  WHEELHOUSE="$_h/wheelhouse"
fi
echo ">> uid=$(id -u) wheelhouse=$WHEELHOUSE"
PY_DEPS=(setuptools wheel pybind11 nanobind cmake "pytest>=8" pytest-cov coverage gcovr atheris)
mkdir -p "$WHEELHOUSE"
if python3 -m pip download --disable-pip-version-check --dest "$WHEELHOUSE" "${PY_DEPS[@]}" >/tmp/wheelhouse.log 2>&1; then
  echo ">> wheelhouse refreshed from PyPI ($WHEELHOUSE)"
else
  echo ">> PyPI unreachable — reusing the distributions already cached in $WHEELHOUSE"
  tail -3 /tmp/wheelhouse.log || true
fi
compgen -G "$WHEELHOUSE/*" >/dev/null \
  || { echo "FATAL: $WHEELHOUSE is empty and PyPI is unreachable — cannot build" >&2; exit 1; }
PIP=(--no-index --find-links "$WHEELHOUSE" --disable-pip-version-check)

# --- sanitizer runtime selection --------------------------------------------------
# pypcode_native.so is compiled with -fsanitize=address, and an ASan runtime must be resolved
# BEFORE the process starts (ASan hooks the allocator from process start; a late in-process dlopen
# does not work). Two runtimes can supply it, and they are NOT equivalent:
#
#   atheris's asan_with_fuzzer.so  -- compiler-rt's ASan *and* libFuzzer in ONE object. Preferred,
#       because it is the libFuzzer that atheris drives, so the extension's SanitizerCoverage
#       counters register with the same engine and native edges become visible to the fuzzer.
#   the toolchain's libclang_rt.asan-x86_64.so -- always present, but it defines
#       __sanitizer_cov_*_init itself, so the native counters are swallowed by ASan's standalone
#       sancov and the fuzzer stays blind to edges inside the C++ decoder.
#
# Which one actually WORKS depends on the atheris build (its bundled runtime can be missing symbols
# the clang that compiled the extension emits), so we do not guess: each candidate is TRIED, in
# preference order, by actually importing pypcode under it. The first that loads wins, and if none
# does the build FAILS loudly rather than shipping a target that cannot start.
LOADLOG=/tmp/pypcode-load.log

# pypcode_loads <venv> <preload> [module...] — import the modules and build a pypcode Context.
# Building a Context loads a compiled .sla, so this proves the whole chain (native extension + the
# 149 sleigh-compiled spec files) is present, not merely that a directory exists. Runs from /tmp so
# the /mayhem source tree cannot satisfy `import pypcode` on its own. Diagnostics go to $LOADLOG.
pypcode_loads() {
  local v="$1" pre="$2"; shift 2
  [ -x "$v/bin/python3" ] || return 1
  (cd /tmp && ASAN_OPTIONS=detect_leaks=0 LD_PRELOAD="$pre" \
     "$v/bin/python3" - "$@" <<'PY' >"$LOADLOG" 2>&1
import importlib, sys
for m in sys.argv[1:]:
    importlib.import_module(m)
import pypcode
arch = next(iter(pypcode.Arch.enumerate()))
pypcode.Context(next(iter(arch.languages)))
PY
  )
}

san_candidates() {
  if [ -x "$FUZZ_VENV/bin/python3" ]; then
    "$FUZZ_VENV/bin/python3" - 2>/dev/null <<'PY'
import os
try:
    import atheris
except Exception:
    pass
else:
    # atheris.path() is the directory the *_with_fuzzer.so runtimes are installed into -- the
    # site-packages root, NOT the atheris package dir (the wheel ships them at the top level).
    try:
        d = atheris.path()
    except Exception:
        d = os.path.dirname(os.path.dirname(os.path.abspath(atheris.__file__)))
    c = os.path.join(d, "asan_with_fuzzer.so")
    if os.path.exists(c):
        print(c)
PY
  fi
  printf '%s\n' "$(clang -print-resource-dir)/lib/linux/libclang_rt.asan-x86_64.so"
}

# pick_preload — echo the first runtime under which the instrumented extension actually loads.
pick_preload() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    if pypcode_loads "$FUZZ_VENV" "$c" atheris; then printf '%s' "$c"; return 0; fi
    echo ">> rejected sanitizer runtime $c:" >&2; tail -4 "$LOADLOG" >&2
  done < <(san_candidates)
  return 1
}

# venv_healthy <venv> [module...] — the unsanitized (test) venv needs no preload.
# This is what makes build.sh idempotent: a re-run on an already-built tree is a near-no-op
# (§6.2 item 9), while a re-run after `git clean -ffdX` has wiped every *.so/*.sla rebuilds.
venv_healthy() { pypcode_loads "$1" "" "${@:2}"; }
fuzz_venv_healthy() { [ -x "$FUZZ_VENV/bin/python3" ] && pick_preload >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# (b) The TEST build: the upstream suite, compiled with the project's NORMAL flags in its own clean
# venv, installed EDITABLE so the PATCH tier can edit /mayhem/pypcode and rebuild. mayhem/test.sh
# only RUNS it; it never compiles.
# ---------------------------------------------------------------------------
build_test_venv() {
  echo ">> building the TEST venv (upstream flags, no sanitizers)"
  rm -rf "$TEST_VENV"
  python3 -m venv "$TEST_VENV"
  "$TEST_VENV/bin/pip" install "${PIP[@]}" setuptools wheel nanobind cmake pytest pytest-cov coverage gcovr
  (
    export CC=clang CXX=clang++
    unset CFLAGS CXXFLAGS LDFLAGS
    # setup.py hardcodes its CMake build dir to $SRC/build/native and CMake only seeds
    # CMAKE_C_FLAGS/CMAKE_CXX_FLAGS from the environment on a FRESH configure — so the two builds
    # below MUST NOT share a cache, or the second silently inherits the first one's flags.
    rm -rf "$SRC/build"
    "$TEST_VENV/bin/pip" install "${PIP[@]}" --no-build-isolation --no-deps -e .
  )
}

# ---------------------------------------------------------------------------
# (a) The FUZZ build: the project itself instrumented with $SANITIZER_FLAGS, in its own venv.
# ---------------------------------------------------------------------------
build_fuzz_venv() {
  echo ">> building the FUZZ venv (instrumented native extension)"
  rm -rf "$FUZZ_VENV" "$SRC/build"
  python3 -m venv "$FUZZ_VENV"
  "$FUZZ_VENV/bin/pip" install "${PIP[@]}" setuptools wheel pybind11 nanobind cmake
  (
    # -fsanitize=fuzzer-no-link (SanitizerCoverage instrumentation, no libFuzzer main) is REQUIRED on
    # top of $SANITIZER_FLAGS: atheris only auto-instruments Python BYTECODE
    # (atheris.instrument_imports() in fuzz_pcode.py) -- it does nothing to a compiled native
    # extension unless that extension is itself built with SanitizerCoverage. Without this flag the
    # real pcode/SLEIGH decoder (a C++ library -- virtually all of pypcode's actual behavior) runs
    # completely uninstrumented.
    #
    # -fno-sanitize=vptr,enum,shift: setup.py's build also compiles+runs the `sleigh` CLI tool
    # (turns .slaspec source into the .sla data files pypcode loads at runtime) as a build step.
    # Under full UBSan it halts on real-but-irrelevant findings scattered across the SLEIGH
    # COMPILER's legacy C++ (slgh_compile.cc: OperandSymbol/LabelSymbol vptr mismatch;
    # semantics.hh: an out-of-range enum load; pcodecompile.cc: a >=64 shift exponent) -- code that
    # only runs at .slaspec-to-.sla build time across all 149 processor specs, never on the fuzzed
    # path (pypcode.Context.translate()/.disassemble() only load already-compiled .sla files).
    # Keep ASan and the rest of UBSan halting; only these three checks are relaxed, and only
    # because they fire in a build-time-only tool, confirmed by running the full 149-file
    # `sleigh -a` compile to completion (rc=0) with exactly this set relaxed.
    #
    # -fno-sanitize=function is relaxed for a DIFFERENT reason -- it is what makes the native
    # SanitizerCoverage edges visible to the fuzzer at all. atheris's asan_with_fuzzer.so (the
    # only runtime whose libFuzzer is the one atheris drives, see pick_preload above) does not
    # ship UBSan's `function` check handler -- it lives in ubsan_cxx, which that build omits --
    # so an extension compiled WITH the check fails to load under it:
    #     ImportError: pypcode_native...so: undefined symbol:
    #                  __ubsan_handle_function_type_mismatch_abort
    # pick_preload then falls back to the toolchain's libclang_rt.asan, which defines
    # __sanitizer_cov_*_init itself and swallows the counters into standalone sancov, leaving the
    # fuzzer blind inside the C++ decoder. Measured cost of that fallback: a 1200s run over the
    # SLEIGH decoder reported edges_covered=5 (run #4, 35.7M executions) -- i.e. only the
    # Python-level atheris instrumentation, no native coverage feedback at all.
    #
    # The trade is explicit: we lose UBSan's indirect-call function-type-mismatch check on the
    # fuzzed code, and gain SanitizerCoverage over the whole pcode/SLEIGH decoder, which is
    # virtually all of pypcode's real behavior. ASan and every other UBSan check stay ON and
    # halting. Prior art in this fleet: unicorn relaxes `function` for its 13 emulator targets.
    # This is safe by construction -- pick_preload TRIES each runtime and the first one under
    # which the extension actually imports wins, so if atheris's runtime still will not load we
    # simply fall back to exactly today's behavior rather than shipping a broken target.
    local flags="$SANITIZER_FLAGS -fno-sanitize=vptr,enum,shift,function -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
    export CFLAGS="$flags" CXXFLAGS="$flags" LDFLAGS="$flags"
    "$FUZZ_VENV/bin/pip" install "${PIP[@]}" --no-build-isolation atheris
    "$FUZZ_VENV/bin/pip" install "${PIP[@]}" --no-build-isolation --no-deps .
  )
}

venv_healthy "$TEST_VENV" pytest && echo ">> TEST venv already built — skipping" || build_test_venv
fuzz_venv_healthy && echo ">> FUZZ venv already built — skipping" || build_fuzz_venv

# ---------------------------------------------------------------------------
# ELF launcher shims.
#
# Mayhem requires the `cmd:` target (and fuzz-smoke) to be an ELF -- it rejects a .py/shebang script.
# pypcode's harness (mayhem/fuzz_pcode.py, standard atheris.Setup(sys.argv,...)/atheris.Fuzz()) and
# the pytest oracle are both pure Python, so these tiny shims are the ELFs that get invoked; they
# exec() into the right venv's python3, forwarding argv untouched (libFuzzer flags for the fuzz
# target, pytest args for the test launcher -- atheris.Fuzz() consumes sys.argv exactly like a
# native libFuzzer binary would).
#
# They are compiled HERE from our own $DEBUG_FLAGS. (A PyInstaller --onefile bundle was tried first
# and rejected: PyInstaller ships a PREBUILT platform bootloader, so the resulting ELF carried an
# uncontrollable DWARF version and failed the DWARF<4 gate, SPEC §6.2 item 10.)
#
# Dynamically linked on purpose (no -static) so verify-repo's sabotage oracle -- an LD_PRELOADed
# constructor that _exit(0)s every non-system ELF -- can neuter them; see mayhem/test.sh.
#
# LD_PRELOAD of a combined ASan+libFuzzer runtime is REQUIRED: pypcode_native.so is compiled with
# -fsanitize=address, and a sanitizer runtime must be resolved BEFORE the process starts (ASan hooks
# the allocator from process start; a late in-process dlopen does not work). We prefer atheris's own
# asan_with_fuzzer.so, which is compiler-rt's ASan *and* libFuzzer in ONE object: that is what makes
# the extension's SanitizerCoverage counters register with the libFuzzer that atheris is driving. The
# plain toolchain libclang_rt.asan-*.so also defines __sanitizer_cov_*_init, so preloading it instead
# would swallow the native counters into ASan's standalone sancov and leave the fuzzer blind to every
# edge in the C++ decoder -- it is kept only as a fallback for an atheris build that ships no such
# object. (The vptr UBSan check is already disabled above, so atheris's separate ubsan_cxx runtime --
# which has an unresolved cross-object dependency on ubsan's own symbols -- is not needed.)
#
# setenv(ASAN_OPTIONS=detect_leaks=0, overwrite=0) covers LSan false-positives on throwaway
# nanobind/C++ objects inside the fuzzed extension. It only fills the key in if Mayhem has not
# already set ASAN_OPTIONS itself (Mayhem still owns every other knob). A build-time
# __lsan_is_turned_off() hook -- the fleet's preferred form -- cannot be used here: the fuzzed code
# is a dlopened Python extension, and glibc resolves __lsan_is_turned_off to the ASan runtime's own
# weak definition (preloaded, hence earlier in the search order) before any object we could link.
# ---------------------------------------------------------------------------
SAN_PRELOAD="$(pick_preload)" || {
  echo "FATAL: no sanitizer runtime loads the instrumented extension (see rejections above)" >&2; exit 1; }
case "$SAN_PRELOAD" in
  *asan_with_fuzzer.so) echo ">> using atheris's combined ASan+libFuzzer runtime (native edges reach the fuzzer)" ;;
  *) echo ">> WARNING: falling back to $SAN_PRELOAD — atheris's asan_with_fuzzer.so is unusable here, so native SanitizerCoverage edges will NOT reach libFuzzer (Python-level atheris coverage still does)" ;;
esac
echo ">> sanitizer runtime preloaded into the harness: $SAN_PRELOAD"

emit_launcher() {   # emit_launcher <out.c> <script-to-exec>
  cat > "$1" <<EOF
#define _GNU_SOURCE
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    setenv("ASAN_OPTIONS", "detect_leaks=0", 0);
    setenv("LD_PRELOAD", "$SAN_PRELOAD", 0);
    char **nv = (char **)malloc((size_t)(argc + 2) * sizeof(char *));
    if (!nv) return 1;
    nv[0] = (char *)"$FUZZ_VENV/bin/python3";
    nv[1] = (char *)"$2";
    for (int i = 1; i < argc; i++) nv[i + 1] = argv[i];
    nv[argc + 1] = NULL;
    execv("$FUZZ_VENV/bin/python3", nv);
    return 127;
}
EOF
}

emit_launcher /tmp/fuzz_launcher.c       "$SRC/mayhem/fuzz_pcode.py"
emit_launcher /tmp/standalone_launcher.c "$SRC/mayhem/standalone_pcode.py"

cat > /tmp/test_launcher.c <<'EOF'
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char **nv = (char **)malloc((size_t)(argc + 3) * sizeof(char *));
    if (!nv) return 1;
    nv[0] = (char *)"/mayhem/test-venv/bin/python3";
    nv[1] = (char *)"-m";
    nv[2] = (char *)"pytest";
    for (int i = 1; i < argc; i++) nv[i + 2] = argv[i];
    nv[argc + 2] = NULL;
    execv("/mayhem/test-venv/bin/python3", nv);
    return 127;
}
EOF

# The fuzz target, the run-once standalone reproducer (one input file, no fuzzing engine — the
# Python equivalent of linking $STANDALONE_FUZZ_MAIN, which cannot be used against an atheris
# harness), and the test-suite launcher. All three carry DWARF <= 3 via $DEBUG_FLAGS (§6.2 item 10).
$CC $DEBUG_FLAGS -O1 -o /mayhem/fuzz-pcode            /tmp/fuzz_launcher.c
$CC $DEBUG_FLAGS -O1 -o /mayhem/fuzz-pcode-standalone /tmp/standalone_launcher.c
$CC $DEBUG_FLAGS -O1 -o /mayhem/pcode-tests           /tmp/test_launcher.c

ls -la /mayhem/fuzz-pcode /mayhem/fuzz-pcode-standalone /mayhem/pcode-tests

# ---------------------------------------------------------------------------
# Self-test: fail the BUILD, not a later fuzz run, if the harness cannot start. The failure this
# guards against is silent -- a sanitizer runtime that loads but is missing a symbol the extension
# needs, or an atheris/libFuzzer combination that refuses to initialise, still leaves three
# perfectly good-looking ELFs behind and only shows up as a dead Mayhem run.
# ---------------------------------------------------------------------------
echo ">> self-test: instrumented pypcode loads under the preloaded runtime"
pypcode_loads "$FUZZ_VENV" "$SAN_PRELOAD" atheris \
  || { echo "FATAL: instrumented pypcode will not load under $SAN_PRELOAD" >&2; cat "$LOADLOG" >&2; exit 1; }
echo ">> self-test: the fuzz target iterates"
if ! /mayhem/fuzz-pcode -runs=1 -max_total_time=60 -timeout=50 >/tmp/fuzz-selftest.log 2>&1; then
  echo "FATAL: /mayhem/fuzz-pcode did not run" >&2; tail -25 /tmp/fuzz-selftest.log >&2; exit 1
fi
tail -2 /tmp/fuzz-selftest.log
