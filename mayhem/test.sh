#!/usr/bin/env bash
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run pytest through the /mayhem/pcode-tests ELF launcher (build.sh), not the venv's pytest
# script directly. That matters for the verify-repo anti-reward-hack check: it LD_PRELOADs a
# constructor that _exit(0)s every NON-system executable. The system python3 the launcher
# exec()s into is spared, but the launcher binary itself is not — so under sabotage it dies
# before pytest ever runs, no junit.xml is produced, and this script reports a failure. The
# normal run is unaffected.
if [ ! -x /mayhem/pcode-tests ]; then
  echo "missing /mayhem/pcode-tests — build.sh should have built the test launcher" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

junit="${SRC}/junit.xml"
# Remove any junit.xml left over from a prior run (e.g. the one this same Dockerfile bakes in
# at build time) -- otherwise a launcher that dies before pytest runs (sabotage oracle) would
# silently read that stale file and report a false pass.
rm -f "$junit"
set +e
/mayhem/pcode-tests -q --tb=no --no-cov --junitxml="$junit" >/tmp/pytest.log 2>&1
rc=$?
set -e

if [ ! -f "$junit" ]; then
  cat /tmp/pytest.log >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

read -r passed failed skipped <<< "$(python3 << 'PY'
import xml.etree.ElementTree as ET
root = ET.parse("junit.xml").getroot()
passed = failed = skipped = 0
for suite in root.iter("testsuite"):
    passed += int(suite.get("tests", 0)) - int(suite.get("failures", 0)) - int(suite.get("errors", 0)) - int(suite.get("skipped", 0))
    failed += int(suite.get("failures", 0)) + int(suite.get("errors", 0))
    skipped += int(suite.get("skipped", 0))
print(passed, failed, skipped)
PY
)"

if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
emit_ctrf "pytest" "$passed" "$failed" "$skipped"
