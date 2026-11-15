"""Execute Henge's actual emitted scalar memory code in Unicorn ARM64.

Run with Python packages unicorn and capstone installed. The test build replaces
only the host DCZID probe (unrelated to scalar loads) on non-ARM build hosts.
No Apple SDK or guest macOS image is used, so this is not an iPad boot test.
"""
import os
import json
import pathlib
import struct
import subprocess
import tempfile

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as regs
from unicorn.arm64_const import UC_ARM64_REG_X28, UC_ARM64_REG_NZCV, UC_ARM64_REG_SP
REGS = [getattr(regs, f"UC_ARM64_REG_X{i}") for i in range(31)]
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

ROOT = pathlib.Path(__file__).resolve().parents[1]
DRIVER = r'''
#include "translate_for_test.c"
#include <stdio.h>
int hv_knob[HV_K_COUNT];
int hv_tlb_tmajor = 1;
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    static HvMachine machine;
    machine.fastmem_enabled = atoi(argv[3]);
    machine.fastmem_diagnostics = atoi(argv[4]);
    machine.fastmem_tlb_first = getenv("HV_FASTMEM_ORDER") && !strcmp(getenv("HV_FASTMEM_ORDER"), "tlb-first");
    machine.tlb_preload = getenv("HV_TLB_PRELOAD") && atoi(getenv("HV_TLB_PRELOAD"));
    E.flat = 1;
    E.w = E.hot; E.m = &machine; E.flags = strtoul(argv[2], 0, 0);
    E.nogroup = 1;
    translate_mem(&E, strtoul(argv[1], 0, 0), 0x1000);
    if (E.nfix) return 3;
    uint32_t success = E.n; put(&E, B_OP);
    cold_on(&E);
    uint32_t misses[MAX_OOL], nmisses = 0;
    for (unsigned i = 0; i < E.nool; i++) {
        Ool *o = &E.ool[i];
        if (o->fastmem) {
            link_here(&E, o->at, 0);
            put_fastmem_fallback(&E, o);
            misses[nmisses++] = E.n; put(&E, B_OP);
        } else misses[nmisses++] = o->at;
    }
    patch_branch(&E.hot[success], (int64_t)E.n - success);
    for (unsigned i = 0; i < nmisses; i++)
        patch_branch(&E.hot[misses[i]], (int64_t)E.n + 1 - misses[i]);
    printf("[");
    for (unsigned i = 0; i < E.n; i++) printf("%s%u", i ? "," : "", E.hot[i]);
    puts("]");
}
'''

CODE, CPU, LUT, DATA = 0x100000, 0x2000000, 0x10000000, 0x20000000
KERNEL, PAGE = 0xfffffe0000000000, 16384
NZCV = 0xa0000000
checked = 0
diagnostic_mode = 0
last_steps = 0

def run(driver, insn, *, flags=1, enabled=1, offset=128, lut=True,
        pointer=True, tlb=True, outside=False, page_end=False, store=False, diagnostics=None, kernel=KERNEL, wrong_tag=False,
        stack_displacement=None, stack_writeback=None):
    global checked, last_steps
    if diagnostics is None: diagnostics = diagnostic_mode
    words = json.loads(subprocess.check_output([str(driver), hex(insn), str(flags), str(enabled), str(diagnostics)]))
    code = struct.pack("<" + "I" * len(words), *words)
    u = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    u.mem_map(CODE, 0x10000)
    u.mem_write(CODE, code + bytes(16))
    u.mem_map(CPU, 0x800000)
    u.mem_map(LUT, 0x800000)
    u.mem_map(DATA, PAGE)
    address = kernel + (1 << 32 if outside else 0) + offset
    page = address & -PAGE
    addend = (DATA - page) & ((1 << 64) - 1)
    table = 0 if not flags & 1 else 2 if flags & 8 else 1
    def q(addr, value): u.mem_write(addr, struct.pack("<Q", value))
    q(CPU + 0x4e8, LUT if pointer else 0)
    q(CPU + 0x4f0, LUT + 0x400000 if pointer else 0)
    q(CPU + 0x4f8, KERNEL)
    if lut:
        entry = LUT + (0x400000 if table == 2 else 0) + ((address >> 14) & 262143) * 16
        q(entry, (page - 15 + ((1 << 32) if outside or wrong_tag else 0)) & ((1 << 64) - 1))
        q(entry + 8, addend)
    slot = (address >> 14) & 16383
    entry = CPU + 0x580 + table * 16384 * 32 + slot * 32
    q(entry, 0x4000)
    q(entry + 8, 0x4000)
    if tlb:
        q(entry, (page - 15) & ((1 << 64) - 1))
        q(entry + 8, (page - 15) & ((1 << 64) - 1))
        q(entry + 24, addend)
    u.mem_write(DATA, bytes([0x82, 0x73, 0x64, 0xf5, 0x46, 0x37, 0x28, 0x19]) * (PAGE // 8))
    for reg in range(31):
        u.reg_write(REGS[reg], 0x9000 + reg)
        q(CPU + reg * 8, 0x9000 + reg)
    rt, rn = insn & 31, (insn >> 5) & 31
    stolen = {6, 7, 15, 18, 28}
    u.reg_write(UC_ARM64_REG_X28, CPU)
    if rn == 31:
        assert stack_displacement is not None
        u.reg_write(UC_ARM64_REG_SP, address-stack_displacement)
    elif rn in stolen: q(CPU + rn * 8, address)
    else: u.reg_write(REGS[rn], address)
    u.reg_write(UC_ARM64_REG_NZCV, NZCV)
    end = CODE + len(code)
    stopped = []
    steps = []
    def hook(emu, pc, size, data):
        steps.append(pc)
        if pc in (end, end + 4):
            stopped.append(pc)
            emu.emu_stop()
    u.hook_add(UC_HOOK_CODE, hook)
    u.emu_start(CODE, end + 8, count=500)
    expected_slow = page_end or (not tlb and (not enabled or not lut or not pointer or outside or wrong_tag or table == 0 or store))
    assert stopped == [end + 4 if expected_slow else end], (insn, stopped, expected_slow)
    assert u.reg_read(UC_ARM64_REG_NZCV) == NZCV
    counters = struct.unpack("<6Q", u.mem_read(CPU + 0x518, 48))
    expected_counters = [0] * 6
    if diagnostics and enabled and table and not store and stack_writeback is None and (os.environ.get("HV_FASTMEM_ORDER") != "tlb-first" or not tlb or page_end):
        expected_counters[0] = 1
        reason = 0 if address < (1 << 63) else 1 if not pointer else 2 if not lut or outside or wrong_tag or page_end else None
        expected_counters[1 if reason is None else 2 + reason] = 1
    assert list(counters) == expected_counters, (hex(insn), counters, expected_counters)
    if not expected_slow:
        if store:
            assert struct.unpack("<Q", u.mem_read(DATA + offset, 8))[0] == (address if rt == rn else 0x9000 + rt)
        else:
            size = 8 if rn == 31 else {0x39400000: 1, 0x79400000: 2, 0xb9400000: 4, 0xf9400000: 8, 0xb9800000: 4}[insn & ~1023]
            expected = int.from_bytes(u.mem_read(DATA + offset, size), "little", signed=(insn & ~1023) == 0xb9800000) & ((1 << 64) - 1)
            actual = struct.unpack("<Q", u.mem_read(CPU + rt * 8, 8))[0] if rt in stolen else u.reg_read(REGS[rt])
            assert actual == expected, (hex(insn), expected, actual)
        if rn == 31:
            assert u.reg_read(UC_ARM64_REG_SP) == address-stack_displacement+(stack_writeback or 0)
    for reg in (2, 3, 4, 5, 8, 9, 16, 17, 19, 20, 27, 29, 30):
        if reg != rt and reg != rn:
            assert u.reg_read(REGS[reg]) == 0x9000 + reg
    last_steps = len(steps)
    checked += 1
    return code

with tempfile.TemporaryDirectory() as temp:
    tmp = pathlib.Path(temp)
    source = (ROOT / "core/translate.c").read_text()
    probe = '__asm__ volatile("mrs %0, dczid_el0" : "=r"(dczid));'
    assert source.count(probe) == 1
    (tmp / "translate_for_test.c").write_text(source.replace(probe, "dczid = 0; /* test host only */"))
    (tmp / "driver.c").write_text(DRIVER)
    driver = tmp / "emit"
    subprocess.run(["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-O2", "-ffunction-sections", "-fdata-sections",
                    "-I" + str(ROOT / "core"), "-I" + str(ROOT / "host"), "-I" + str(ROOT / "devices"),
                    str(tmp / "driver.c"), str(ROOT / "core/memop.c"), "-Wl,--gc-sections", "-o", str(driver)], check=True)
    for order in ("lut-first", "tlb-first"):
      os.environ["HV_FASTMEM_ORDER"] = order
      for preload in ("0", "1"):
        os.environ["HV_TLB_PRELOAD"] = preload
        for diagnostic_mode in (0, 1):
            for insn in (0x39400020, 0x79400020, 0xb9400020, 0xf9400020, 0xb9800020):
                for flags in (1, 9):
                    for offset in (0, 1, 7, 128, PAGE - 16):
                        run(driver, insn, flags=flags, offset=offset, tlb=False)
                    for args in ({"lut": False}, {"pointer": False}, {"outside": True}, {"enabled": 0},
                                 {"lut": False, "tlb": False}, {"offset": PAGE - 8, "page_end": True}):
                        run(driver, insn, flags=flags, **args)
                run(driver, insn, flags=0, lut=False)
            run(driver, 0xf9000020, store=True)
            for rt in (0, 6, 7, 15, 18, 28, 29, 30):
                for rn in (1, 6, 7, 15, 18, 28, 29, 30):
                    insn = 0xf9400000 | rn << 5 | rt
                    run(driver, insn, tlb=False)
                    run(driver, insn, lut=False)
            for kernel in (0xfffffcf000000000, 0xfffffc0400000000, 0xfffffe1000000000):
                for flags in (1, 9):
                    run(driver, 0xf9400020, kernel=kernel, flags=flags, tlb=False)
                    run(driver, 0xf9400020, kernel=kernel, flags=flags, wrong_tag=True, tlb=False)
            for kernel in (0, 0x10000, 0x7fff000000000000):
                run(driver, 0xf9400020, kernel=kernel, lut=False, tlb=True)
            # An all-zero slot cannot accept an EL1 access to user VA zero.
            run(driver, 0xf9400020, kernel=0, offset=0, lut=False, tlb=False)
            code = run(driver, 0xf9400020, tlb=False)
    os.environ["HV_FASTMEM_ORDER"] = "tlb-first"
    for preload in ("0","1"):
        os.environ["HV_TLB_PRELOAD"] = preload
        run(driver,0xf9400020,enabled=0,tlb=True)
        reference_steps=last_steps
        run(driver,0xf9400020,enabled=1,tlb=True)
        assert last_steps==reference_steps, "TLB-first must add no executed instructions to a warm TLB hit"
        for insn, displacement, writeback, storing in (
            (0xf94013e0,32,None,False), (0xf90013e0,32,None,True),
            (0xf94813e0,4128,None,False),
            (0xf85e03e0,-32,None,False), (0xf85f0fe0,-16,-16,False),
            (0xf84107e0,0,16,False),
        ):
            for flags in (0,1,9):
                run(driver,insn,flags=flags,stack_displacement=displacement,stack_writeback=writeback,store=storing)
                run(driver,insn,flags=flags,stack_displacement=displacement,stack_writeback=writeback,store=storing,lut=False,tlb=False)
        folded=run(driver,0xf94013e0,stack_displacement=32)
        assert b'\xe6\x83\x00\x91' in folded, 'SP+32 folds into ADD x6,sp,#32'
        assert b'\xe6\x03\x00\x91' not in folded, 'No redundant MOV x6,sp before SP+32'
    print(f"{checked} emitted ARM64 memory cases passed (Unicorn; not device execution)")
    print("Guard disassembly:")
    for item in list(Cs(CS_ARCH_ARM64, CS_MODE_ARM).disasm(code, CODE))[:17]:
        print(f"  {item.mnemonic} {item.op_str}")
