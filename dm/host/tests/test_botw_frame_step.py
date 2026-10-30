#!/usr/bin/env python3
"""Execute the actual BotW VFR prefix and production veneer with Unicorn.

Usage: test_botw_frame_step.py <original main NSO> <work folder>
Game-derived images and disassembly stay in that work folder.
"""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

import lz4.block
import unicorn as uc
from unicorn import arm64_const as arm

repo = Path(__file__).resolve().parents[3]


def main():
    source, work = Path(sys.argv[1]), Path(sys.argv[2])
    work.mkdir(parents=True, exist_ok=True)
    nso = source.read_bytes()
    flags = struct.unpack_from('<I', nso, 12)[0]
    segments = [struct.unpack_from('<III', nso, 16 + 16 * i) for i in range(3)]
    sizes = struct.unpack_from('<III', nso, 0x60)
    bss = struct.unpack_from('<I', nso, 0x3c)[0]
    image = bytearray(segments[2][1] + segments[2][2] + bss)
    for i, (file_offset, memory_offset, length) in enumerate(segments):
        data = nso[file_offset:file_offset + sizes[i]]
        if flags >> i & 1:
            data = lz4.block.decompress(data, uncompressed_size=length)
        image[memory_offset:memory_offset + length] = data
    original, patched, info = work/'original.bin', work/'patched.bin', work/'patch.json'
    original.write_bytes(image)
    helper = repo/'dm/host/tests/build/t_timing_mac'
    subprocess.run([str(helper), '--apply', str(original), str(patched), nso[0x40:0x50].hex(),
                    str(segments[0][1] + segments[0][2]), str(segments[1][1]), str(info)],
                   env=dict(os.environ, DM_FPS='120'), check=True)
    meta, candidate = json.loads(info.read_text()), patched.read_bytes()
    base, obj, stack = 0x10000000, 0x20000000, 0x30000000
    checks = 0

    def execute(code, ratio, current=1, request=1, override=False, override_value=2):
        emulator = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        emulator.mem_map(base, (len(code) + 0xffff) & ~0xffff)
        emulator.mem_write(base, code)
        emulator.mem_map(obj, 0x10000)
        emulator.mem_map(stack, 0x10000)
        state = bytearray(0x160)
        state[0x29] = int(override)
        struct.pack_into('<II', state, 0x2c, override_value, 0x3f000000)
        struct.pack_into('<I', state, 0x34, current)
        struct.pack_into('<f', state, 0x3c, .5)
        struct.pack_into('<I', state, 0x150, 2)
        emulator.mem_write(obj, bytes(state))
        emulator.mem_write(base + meta['data'], struct.pack('<f', ratio))
        emulator.reg_write(arm.UC_ARM64_REG_X0, obj)
        emulator.reg_write(arm.UC_ARM64_REG_X1, request)
        emulator.reg_write(arm.UC_ARM64_REG_SP, stack + 0x8000)
        emulator.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)
        emulator.emu_start(base + 0x151d3d0, base + 0x151d494, count=200)
        actual = emulator.mem_read(obj, len(state))
        published_ratio, published_override = struct.unpack('<fI', emulator.mem_read(base + meta['data'] + 8, 8))
        if code is candidate:
            assert abs(published_ratio - struct.unpack_from('<f', actual, 0x3c)[0]) < 1e-6
            assert bool(published_override) == override
        return actual

    # Give the original image the same mapped data-page extent for the negative
    # control. Its own instructions never use the added value.
    reference = bytes(image).ljust(len(candidate), b'\0')
    for fps in [15, 20, 25, 30, 50, 60, 75, 90, 100, 120]:
        ratio = 30.0 / fps
        for current in [1, 2, 3]:
            for requested in [1, 2, 3]:
                state = execute(candidate, ratio, current, requested)
                assert abs(struct.unpack_from('<f', state, 0x30)[0] - ratio) < 1e-6
                assert abs(struct.unpack_from('<f', state, 0x3c)[0] - ratio) < 1e-6
                checks += 2
        if fps > 60:
            state = execute(reference, ratio)
            assert abs(struct.unpack_from('<f', state, 0x3c)[0] - ratio) > .01
            checks += 1
        for current in [1, 2, 3]:
            for value in [0, 1, 2, 3]:
                before = execute(reference, ratio, current, override=True, override_value=value)
                after = execute(candidate, ratio, current, override=True, override_value=value)
                assert before == after, (fps, current, value)
                checks += 1
    result = {'checks': checks, 'failed': 0, 'build': nso[0x40:0x50].hex(), 'patch': meta}
    (work/'instruction-results.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
