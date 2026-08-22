#!/mayhem/fuzz-venv/bin/python3
import atheris
import sys

import fuzz_helpers as fh

with atheris.instrument_imports():
    import pypcode

chosen_arch: pypcode.Arch = list(pypcode.Arch.enumerate())[0]
chosen_lang = list(chosen_arch.languages)[0]
context = pypcode.Context(chosen_lang)

possible_flags = [pypcode.TranslateFlags.BB_TERMINATING, None]
def TestOneInput(data):
    fdp = fh.EnhancedFuzzedDataProvider(data)

    try:
        buff = fdp.ConsumeRandomBytes()
        buff_len = len(buff)
        # disassemble()/translate() reject offset >= len(buf) with IndexError ("offset out of range",
        # pypcode_native.cpp) before decoding anything, so only generate valid offsets: an empty buffer
        # has none. Any IndexError that still escapes is then unexpected and crashes deterministically.
        if buff_len == 0:
            return -1
        # Addresses are unsigned: ConsumeInt() is SIGNED, and a negative value reaches the binding as a
        # uint64 near 2**64, where base + len wraps and every byte read is "outside buffer range".
        base_addr = fdp.ConsumeIntInRange(0, (1 << (64 if '64' in chosen_arch.archname else 32)) - 1)
        off = fdp.ConsumeIntInRange(0, buff_len - 1)
        max_bytes = fdp.ConsumeIntInRange(0, buff_len - off)
        max_ins = fdp.ConsumeIntInRange(0, 100)
        flag = fdp.PickValueInList(possible_flags)
        if fdp.ConsumeBool():
            context.translate(buff, base_addr, off, max_bytes, max_ins, flag)
        else:
            context.disassemble(buff, base_addr, off, max_bytes, max_ins)
    except (pypcode.BadDataError, pypcode.DecoderError, pypcode.UnimplError):
        return -1
    except TypeError as e:
        if 'incompatible' in str(e):
            return -1
        raise e


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
