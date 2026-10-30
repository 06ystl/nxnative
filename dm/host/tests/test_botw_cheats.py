#!/usr/bin/env python3
"""Check optional cheats against the actual BotW 1.9.0 instructions.

Usage: test_botw_cheats.py <original main NSO> <game work folder>
Requires the existing game-tool lz4 and Unicorn environment. Game-derived files
stay in the supplied work folder. Uses the production C patcher, not a reimplementation.
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
    source, work = map(Path, sys.argv[1:])
    work.mkdir(parents=True, exist_ok=True)
    nso = source.read_bytes()
    build = nso[0x40:0x50].hex()
    assert build == 'cd57b23fa4bbad65803d9788c01821ee', build
    flags = struct.unpack_from('<I', nso, 12)[0]
    segments = [struct.unpack_from('<III', nso, 16 + 16*i) for i in range(3)]
    sizes = struct.unpack_from('<III', nso, 0x60)
    image = bytearray(segments[2][1] + segments[2][2] + struct.unpack_from('<I', nso, 0x3c)[0])
    for i, (off, mem, length) in enumerate(segments):
        data = nso[off:off+sizes[i]]
        if flags >> i & 1:
            data = lz4.block.decompress(data, uncompressed_size=length)
        image[mem:mem+length] = data
    original = work/'original.bin'
    original.write_bytes(image)
    helper = repo/'dm/host/tests/build/t_cheats_mac'
    text_end, ro = segments[0][1]+segments[0][2], segments[1][1]
    checks = 0

    def patch(source, name, option):
        out = work/(name+'.bin')
        subprocess.run([str(helper), '--apply', str(source), str(out), build,
                        str(text_end), str(ro), option], check=True)
        return out.read_bytes()

    reference = bytes(image)
    assert patch(original, 'disabled', 'none') == reference
    checks += 1
    base, obj = 0x10000000, 0x20000000

    def execute(code, offset, end, values, memory):
        machine = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        machine.mem_map(base, (len(code)+0xffff)&~0xffff)
        machine.mem_write(base, code)
        machine.mem_map(obj, 0x10000)
        machine.mem_write(obj, memory)
        machine.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)
        for register, value in values.items():
            machine.reg_write(register, value)
        machine.emu_start(base+offset, base+end, count=32)
        assert machine.reg_read(arm.UC_ARM64_REG_PC) == base+end
        return machine

    for name, site in [('health',0xcc4e70), ('stamina',0xcc7444),
                       ('arrows',0xd93844), ('durability',0x7ac524)]:
        candidate = patch(original, name, name)
        for enabled, code in [(False,reference), (True,candidate)]:
            if name == 'health':
                machine = execute(code,site,site+4,{arm.UC_ARM64_REG_X21:obj,
                    arm.UC_ARM64_REG_W25:8},struct.pack('<I',12))
                assert struct.unpack('<I',machine.mem_read(obj,4))[0] == (12 if enabled else 8)
            elif name == 'stamina':
                memory = bytearray(0xac)
                struct.pack_into('<ff',memory,0xa4,.25,2.)
                machine = execute(code,site,site+4,{arm.UC_ARM64_REG_X0:obj},bytes(memory))
                result = struct.unpack('<f',struct.pack('<I',machine.reg_read(arm.UC_ARM64_REG_S0)))[0]
                assert result == (2. if enabled else .25)
                assert machine.mem_read(obj,len(memory)) == memory
            elif name == 'arrows':
                machine = execute(code,site,site+4,{arm.UC_ARM64_REG_W2:5},b'\0'*4)
                assert machine.reg_read(arm.UC_ARM64_REG_W22) == (0 if enabled else 5)
            else:
                # Execute both branches through the production veneer and the
                # real return-site comparison, including an exhausted item.
                for durability in [0,1,80,-3]:
                    machine = execute(code,site,site+8,{arm.UC_ARM64_REG_X0:obj},struct.pack('<i',durability))
                    expected = 60000 if enabled else durability
                    assert machine.reg_read(arm.UC_ARM64_REG_W8) == expected & 0xffffffff
                    assert struct.unpack('<i',machine.mem_read(obj,4))[0] == expected
                    assert machine.reg_read(arm.UC_ARM64_REG_X0) == obj
                    checks += 3
            checks += 1
    # Both loader adapters must coexist in the real text padding. The timing
    # helper emits its production veneer; selected cheats cannot overwrite it.
    timed = work/'timed.bin'
    subprocess.run([str(repo/'dm/host/tests/build/t_timing_mac'), '--apply',
        str(original), str(timed), build, str(text_end), str(ro), str(work/'timing.json')],
        env=dict(os.environ,DM_FPS='60'),check=True)
    combined = patch(timed,'combined','health,stamina,durability,arrows')
    timed_bytes = timed.read_bytes()
    assert combined[0x15a1c70:0x15a1cac] == timed_bytes[0x15a1c70:0x15a1cac]
    checks += 1
    result = {'checks':checks,'failed':0,'build':build,'options':['health','stamina','durability','arrows']}
    (work/'instruction-results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__ == '__main__':
    main()
