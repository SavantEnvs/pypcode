#!/mayhem/fuzz-venv/bin/python3
"""
Run-once (NON-fuzzer) reproducer for the fuzz-pcode harness.

The C driver the base image ships as $STANDALONE_FUZZ_MAIN can only be linked against a native
LLVMFuzzerTestOneInput; this harness is an atheris/Python one, so this script is its equivalent:
it feeds each input file to the very same TestOneInput() the fuzzer drives, exactly once, with no
fuzzing engine in the process. A crash therefore surfaces naturally (ASan/UBSan report + backtrace)
which is what crash triage and the RL defect tier need.

    /mayhem/fuzz-pcode-standalone <input-file> [more-input-files...]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fuzz_pcode  # noqa: E402  (path shim must run first)


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <input-file> [input-file...]", file=sys.stderr)
        return 2
    for path in sys.argv[1:]:
        with open(path, "rb") as fh:
            data = fh.read()
        print(f"Running: {path} ({len(data)} bytes)", file=sys.stderr)
        fuzz_pcode.TestOneInput(data)
    print(f"Executed {len(sys.argv) - 1} input(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
