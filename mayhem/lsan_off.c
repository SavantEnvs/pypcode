/*
 * The sanctioned build-time LeakSanitizer off-switch (SPEC §6.2 item 15).
 * Turns off ONLY the leak check; ASan and UBSan stay fully active and halting.
 *
 * Built by mayhem/build.sh into /mayhem/lsan_off.so and LD_PRELOADed (right after the ASan
 * runtime) into the python3 process behind every sanitized launcher: /mayhem/fuzz-pcode and
 * /mayhem/fuzz-pcode-standalone. It has to live in a preloaded object: the ASan runtime
 * (atheris's asan_with_fuzzer.so or libclang_rt.asan) only holds a weak UNDEFINED reference
 * to this symbol, resolved against the process's global scope (executable + LD_PRELOAD list).
 * The executable is the stock python3 and pypcode_native.so is dlopened RTLD_LOCAL, so a
 * definition in either would never be seen.
 */
int __lsan_is_turned_off(void) { return 1; }
