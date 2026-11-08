#!/usr/bin/env python3
"""
recompile.py — static recompiler: NES 6502 (MMC1) machine code -> C.

Reads *your own* ROM dump and emits Sources/NESCore/generated/recomp_gen.c.
Nothing from the ROM is shipped with this project; the C is generated locally.

How it works
  * Recursive-descent disassembly per (16 KiB PRG bank, CPU window) from the
    reset/NMI/IRQ vectors and from optional coverage seeds (addresses the
    runtime had to interpret, see --coverage).
  * Every decoded instruction is translated into C using the same macros as
    the reference interpreter (nes_internal.h), with static addressing-mode
    specialisation (zero-page/RAM/ROM accesses become direct array reads).
  * Code is grouped into blocks (one C function each). A block can be entered
    at any of its instructions via an entry switch, so interrupts returning
    mid-block and computed jumps never need the interpreter.
  * Cycle counting is exact per instruction (incl. page-cross and branch
    penalties). Blocks exit to the dispatcher whenever the scheduler deadline
    (next scanline / NMI / mapper bank switch) is reached.
"""
import argparse, os, sys, zlib, glob, heapq

M_IMP, M_ACC, M_IMM, M_ZP, M_ZPX, M_ZPY, M_ABS, M_ABX, M_ABY, M_IND, M_IZX, M_IZY, M_REL = range(13)
LEN = {M_IMP: 1, M_ACC: 1, M_IMM: 2, M_ZP: 2, M_ZPX: 2, M_ZPY: 2, M_ABS: 3, M_ABX: 3, M_ABY: 3,
       M_IND: 3, M_IZX: 2, M_IZY: 2, M_REL: 2}

OPS = {}
def op(code, ins, mode, cyc, pen=0): OPS[code] = (ins, mode, cyc, pen)

for ins, base in (('ORA', 0x00), ('AND', 0x20), ('EOR', 0x40), ('ADC', 0x60), ('LDA', 0xA0), ('CMP', 0xC0), ('SBC', 0xE0)):
    op(base | 0x09, ins, M_IMM, 2); op(base | 0x05, ins, M_ZP, 3); op(base | 0x15, ins, M_ZPX, 4)
    op(base | 0x0D, ins, M_ABS, 4); op(base | 0x1D, ins, M_ABX, 4, 1); op(base | 0x19, ins, M_ABY, 4, 1)
    op(base | 0x01, ins, M_IZX, 6); op(base | 0x11, ins, M_IZY, 5, 1)
op(0x85, 'STA', M_ZP, 3); op(0x95, 'STA', M_ZPX, 4); op(0x8D, 'STA', M_ABS, 4); op(0x9D, 'STA', M_ABX, 5)
op(0x99, 'STA', M_ABY, 5); op(0x81, 'STA', M_IZX, 6); op(0x91, 'STA', M_IZY, 6)
for ins, base in (('ASL', 0x00), ('ROL', 0x20), ('LSR', 0x40), ('ROR', 0x60)):
    op(base | 0x0A, ins, M_ACC, 2); op(base | 0x06, ins, M_ZP, 5); op(base | 0x16, ins, M_ZPX, 6)
    op(base | 0x0E, ins, M_ABS, 6); op(base | 0x1E, ins, M_ABX, 7)
for ins, base in (('DEC', 0xC0), ('INC', 0xE0)):
    op(base | 0x06, ins, M_ZP, 5); op(base | 0x16, ins, M_ZPX, 6); op(base | 0x0E, ins, M_ABS, 6); op(base | 0x1E, ins, M_ABX, 7)
for code, ins in ((0x90, 'BCC'), (0xB0, 'BCS'), (0xF0, 'BEQ'), (0x30, 'BMI'), (0xD0, 'BNE'), (0x10, 'BPL'), (0x50, 'BVC'), (0x70, 'BVS')):
    op(code, ins, M_REL, 2)
op(0x24, 'BIT', M_ZP, 3); op(0x2C, 'BIT', M_ABS, 4); op(0x00, 'BRK', M_IMP, 7)
for code, ins in ((0x18, 'CLC'), (0xD8, 'CLD'), (0x58, 'CLI'), (0xB8, 'CLV'), (0x38, 'SEC'), (0xF8, 'SED'), (0x78, 'SEI'),
                  (0xCA, 'DEX'), (0x88, 'DEY'), (0xE8, 'INX'), (0xC8, 'INY'), (0xEA, 'NOP'), (0xAA, 'TAX'), (0xA8, 'TAY'),
                  (0xBA, 'TSX'), (0x8A, 'TXA'), (0x9A, 'TXS'), (0x98, 'TYA')):
    op(code, ins, M_IMP, 2)
op(0xE0, 'CPX', M_IMM, 2); op(0xE4, 'CPX', M_ZP, 3); op(0xEC, 'CPX', M_ABS, 4)
op(0xC0, 'CPY', M_IMM, 2); op(0xC4, 'CPY', M_ZP, 3); op(0xCC, 'CPY', M_ABS, 4)
op(0x4C, 'JMP', M_ABS, 3); op(0x6C, 'JMP', M_IND, 5); op(0x20, 'JSR', M_ABS, 6)
op(0xA2, 'LDX', M_IMM, 2); op(0xA6, 'LDX', M_ZP, 3); op(0xB6, 'LDX', M_ZPY, 4); op(0xAE, 'LDX', M_ABS, 4); op(0xBE, 'LDX', M_ABY, 4, 1)
op(0xA0, 'LDY', M_IMM, 2); op(0xA4, 'LDY', M_ZP, 3); op(0xB4, 'LDY', M_ZPX, 4); op(0xAC, 'LDY', M_ABS, 4); op(0xBC, 'LDY', M_ABX, 4, 1)
op(0x48, 'PHA', M_IMP, 3); op(0x08, 'PHP', M_IMP, 3); op(0x68, 'PLA', M_IMP, 4); op(0x28, 'PLP', M_IMP, 4)
op(0x40, 'RTI', M_IMP, 6); op(0x60, 'RTS', M_IMP, 6); op(0xEB, 'SBC', M_IMM, 2)
op(0x86, 'STX', M_ZP, 3); op(0x96, 'STX', M_ZPY, 4); op(0x8E, 'STX', M_ABS, 4)
op(0x84, 'STY', M_ZP, 3); op(0x94, 'STY', M_ZPX, 4); op(0x8C, 'STY', M_ABS, 4)
for c in (0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA): op(c, 'NOP', M_IMP, 2)
for c in (0x80, 0x82, 0x89, 0xC2, 0xE2): op(c, 'NOP', M_IMM, 2)
for c in (0x04, 0x44, 0x64): op(c, 'NOP', M_ZP, 3)
for c in (0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4): op(c, 'NOP', M_ZPX, 4)
op(0x0C, 'NOP', M_ABS, 4)
for c in (0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC): op(c, 'NOP', M_ABX, 4, 1)

TERMINATORS = {'JMP', 'JSR', 'RTS', 'RTI', 'BRK'}
BRANCH_COND = {'BCC': 'COND_BCC', 'BCS': 'COND_BCS', 'BNE': 'COND_BNE', 'BEQ': 'COND_BEQ',
               'BPL': 'COND_BPL', 'BMI': 'COND_BMI', 'BVC': 'COND_BVC', 'BVS': 'COND_BVS'}
MAX_BLOCK = 256


class Rom:
    def __init__(self, path):
        d = open(path, 'rb').read()
        if d[:4] != b'NES\x1a':
            sys.exit('not an iNES file')
        mapper = (d[6] >> 4) | (d[7] & 0xF0)
        if mapper != 1:
            sys.exit('only MMC1 (mapper 1) ROMs are supported, got mapper %d' % mapper)
        off = 16 + (512 if d[6] & 4 else 0)
        self.banks = d[4]
        self.prg = d[off:off + self.banks * 16384]
        self.crc = zlib.crc32(self.prg) & 0xFFFFFFFF
        self.last = self.banks - 1
        self.overlays = []   # (rom bank, offset in bank, ram address, length): code the game copies to PRG-RAM

    def window(self, bank, win):
        """(start, end) CPU address range of a code window."""
        if win == 2:
            ob, off, ram, ln = self.overlays[bank]
            return ram, ram + ln
        base = 0x8000 + win * 0x4000
        return base, base + 0x4000

    def byte(self, bank, win, addr):
        if win == 2:
            ob, off, ram, ln = self.overlays[bank]
            return self.prg[ob * 16384 + off + (addr - ram)]
        base = 0x8000 + win * 0x4000
        return self.prg[bank * 16384 + (addr - base)]


class Insn:
    __slots__ = ('addr', 'opc', 'ins', 'mode', 'cyc', 'pen', 'operand', 'size')


def decode(rom, bank, win, addr):
    lo, hi = rom.window(bank, win)
    if not (lo <= addr < hi):
        return None
    opc = rom.byte(bank, win, addr)
    if opc not in OPS:
        return None
    ins, mode, cyc, pen = OPS[opc]
    size = LEN[mode]
    if addr + size > hi:
        return None
    i = Insn()
    i.addr, i.opc, i.ins, i.mode, i.cyc, i.pen, i.size = addr, opc, ins, mode, cyc, pen, size
    if size == 2:
        i.operand = rom.byte(bank, win, addr + 1)
    elif size == 3:
        i.operand = rom.byte(bank, win, addr + 1) | (rom.byte(bank, win, addr + 2) << 8)
    else:
        i.operand = None
    return i


def target_ctx(rom, bank, win, target):
    """Context (bank, win) for a static control-flow target, or None if unknown."""
    if 0x6000 <= target < 0x8000:
        for k, (ob, off, ram, ln) in enumerate(rom.overlays):
            if ram <= target < ram + ln:
                return (k, 2)
        return None
    if target < 0x8000:
        return None
    tw = (target >> 14) & 1
    if tw == win:
        return (bank, win)
    if win == 2:
        return (rom.last, 1) if tw == 1 else None
    if tw == 1:
        return (rom.last, 1)   # fixed bank at $C000 (MMC1 mode 3)
    return None                # $8000 from fixed code: bank depends on runtime state


class Recompiler:
    def __init__(self, rom):
        self.rom = rom
        self.blocks = {}            # (bank, win, start) -> [Insn]
        self.owner = {}             # (bank, win, addr) -> block key
        self.queue = []
        self.seen = set()
        self.switchers = self.find_bank_switchers()
        self.tablejumps = self.find_table_jumps()

    def find_bank_switchers(self):
        """Fixed-bank routines that write A to the MMC1 PRG register (5x STA $E000-$FFFF / LSR A, RTS)."""
        found = set()
        rom, last = self.rom, self.rom.last
        for start in range(0xC000, 0xFFF0):
            a, stores, ok = start, 0, False
            for _ in range(12):
                i = decode(rom, last, 1, a)
                if i is None: break
                if i.ins == 'STA' and i.mode == M_ABS and i.operand >= 0xE000: stores += 1
                elif i.ins == 'LSR' and i.mode == M_ACC: pass
                elif i.ins == 'RTS': ok = stores == 5; break
                else: break
                a += i.size
            if ok and decode(rom, last, 1, start).ins == 'STA':
                found.add(start)
        return found

    def find_table_jumps(self):
        """Routines of the form ASL A / TAY / PLA / STA zp / PLA / STA zp ... JMP (zp): the caller's
        JSR is followed by an inline table of handler addresses indexed by A."""
        found = set()
        rom, last = self.rom, self.rom.last
        for start in range(0xC000, 0xFFF0):
            seq = []
            a = start
            for _ in range(20):
                i = decode(rom, last, 1, a)
                if i is None: break
                seq.append(i)
                if i.ins == 'JMP': break
                a += i.size
            names = [i.ins for i in seq]
            if names[:6] == ['ASL', 'TAY', 'PLA', 'STA', 'PLA', 'STA'] and seq[0].mode == M_ACC \
                    and seq[-1].ins == 'JMP' and seq[-1].mode == M_IND:
                found.add(start)
        return found

    def table_targets(self, bank, win, at):
        out = []
        lo, hi = self.rom.window(bank, win)
        for k in range(128):
            p = at + 2 * k
            if p + 1 >= hi: break
            if k and (bank, win, p) in self.owner: break
            t = self.rom.byte(bank, win, p) | (self.rom.byte(bank, win, p + 1) << 8)
            if t < 0x6000: break
            out.append(t)
        return out

    def enqueue(self, bank, win, addr, kb=-1):
        nb = len(self.rom.overlays) if win == 2 else self.rom.banks
        if not (0 <= bank < nb):
            return
        k = (bank, win, addr, kb if win != 0 else -1)
        if k not in self.seen:
            self.seen.add(k)
            heapq.heappush(self.queue, k)   # lowest address first -> longest blocks

    def ctx(self, bank, win, target, kb):
        c = target_ctx(self.rom, bank, win, target)
        if c is None and win != 0 and 0x8000 <= target < 0xC000 and kb >= 0:
            return (kb, 0)   # $8000 window from fixed code with statically known bank
        return c

    def run(self):
        while self.queue:
            bank, win, addr, kb = heapq.heappop(self.queue)
            if (bank, win, addr) not in self.owner:
                self.build_block(bank, win, addr)
            self.scan(bank, win, addr, kb)

    def scan(self, bank, win, start, kb):
        """Follow control flow from start, enqueueing successors. Tracks the PRG bank
        selected through bank-switch helpers so calls into $8000-$BFFF resolve."""
        a, const_a = start, None
        for _ in range(MAX_BLOCK):
            i = decode(self.rom, bank, win, a)
            if i is None:
                return
            nxt = a + i.size
            if i.mode == M_REL:
                t = (nxt + (i.operand - 256 if i.operand >= 128 else i.operand)) & 0xFFFF
                c = self.ctx(bank, win, t, kb)
                if c: self.enqueue(c[0], c[1], t, kb)
            if i.ins in ('JMP', 'JSR') and i.mode == M_ABS:
                if i.ins == 'JSR' and win != 0 and i.operand in self.switchers:
                    kb = (const_a & 0x0F) % self.rom.banks if const_a is not None else -1
                else:
                    c = self.ctx(bank, win, i.operand, kb)
                    if c: self.enqueue(c[0], c[1], i.operand, kb)
            if i.ins == 'JSR' and i.operand in self.tablejumps:
                for t in self.table_targets(bank, win, nxt):
                    c = self.ctx(bank, win, t, kb)
                    if c and decode(self.rom, c[0], c[1], t) is not None:
                        self.enqueue(c[0], c[1], t, kb)
                return
            if i.ins == 'JSR':
                self.enqueue(bank, win, nxt, kb)
            if i.ins in TERMINATORS:
                return
            # constant tracking for A (enough for "LDA #n / JSR switch")
            if i.ins == 'LDA' and i.mode == M_IMM: const_a = i.operand
            elif i.ins in ('LDA', 'ADC', 'SBC', 'AND', 'ORA', 'EOR', 'PLA', 'TXA', 'TYA') or \
                    (i.ins in ('ASL', 'LSR', 'ROL', 'ROR') and i.mode == M_ACC): const_a = None
            a = nxt
        self.enqueue(bank, win, a, kb)

    def build_block(self, bank, win, start):
        insns = []
        a = start
        while len(insns) < MAX_BLOCK:
            if insns and (bank, win, a) in self.owner:
                break  # flow into code that already has a block
            i = decode(self.rom, bank, win, a)
            if i is None:
                break
            insns.append(i)
            if i.ins in TERMINATORS:
                break
            a += i.size
        if not insns:
            return
        key = (bank, win, start)
        self.blocks[key] = insns
        for i in insns:
            self.owner.setdefault((bank, win, i.addr), key)

    # ------------------------------------------------------------------ codegen
    @staticmethod
    def rd_static(addr):
        if addr < 0x2000: return 'n->ram[0x%03X]' % (addr & 0x7FF)
        if addr >= 0x8000: return 'rd_prg(n, 0x%04X)' % addr
        if addr >= 0x6000: return 'n->prgram[0x%04X]' % (addr & 0x1FFF)
        return 'RD(0x%04X)' % addr

    @staticmethod
    def rd_indexed(base, reg):
        ea = '(uint16_t)(0x%04X + n->%s)' % (base, reg)
        if base + 0xFF < 0x2000: return 'n->ram[(0x%04X + n->%s) & 0x7FF]' % (base, reg)
        if base >= 0x8000 and base + 0xFF <= 0xFFFF: return 'rd_prg(n, %s)' % ea
        if 0x6000 <= base and base + 0xFF < 0x8000: return 'n->prgram[(0x%04X + n->%s) & 0x1FFF]' % (base, reg)
        return 'RD(%s)' % ea

    @staticmethod
    def wr_static(addr, v):
        if addr < 0x2000: return 'n->ram[0x%03X] = %s;' % (addr & 0x7FF, v)
        if 0x6000 <= addr < 0x8000: return 'n->prgram[0x%04X] = %s;' % (addr & 0x1FFF, v)
        return 'WR(0x%04X, %s);' % (addr, v)

    @staticmethod
    def wr_indexed(base, reg, v):
        if base + 0xFF < 0x2000: return 'n->ram[(0x%04X + n->%s) & 0x7FF] = %s;' % (base, reg, v)
        if 0x6000 <= base and base + 0xFF < 0x8000: return 'n->prgram[(0x%04X + n->%s) & 0x1FFF] = %s;' % (base, reg, v)
        return 'WR((uint16_t)(0x%04X + n->%s), %s);' % (base, reg, v)

    def operand_read(self, i, pre):
        """Returns C expression for the operand value; may append setup lines to pre."""
        m, o = i.mode, i.operand
        if m == M_IMM: return '0x%02X' % o
        if m == M_ZP: return 'n->ram[0x%02X]' % o
        if m == M_ZPX: return 'n->ram[(uint8_t)(0x%02X + n->x)]' % o
        if m == M_ZPY: return 'n->ram[(uint8_t)(0x%02X + n->y)]' % o
        if m == M_ABS: return self.rd_static(o)
        if m in (M_ABX, M_ABY):
            reg = 'x' if m == M_ABX else 'y'
            if i.pen: pre.append('CYC(PAGECROSS(0x%04X, n->%s));' % (o, reg))
            return self.rd_indexed(o, reg)
        if m == M_IZX:
            pre.append('{ uint8_t _z = (uint8_t)(0x%02X + n->x); _ea = (uint16_t)(n->ram[_z] | (n->ram[(uint8_t)(_z + 1)] << 8)); }' % o)
            return 'RD(_ea)'
        if m == M_IZY:
            pre.append('{ uint16_t _b = (uint16_t)(n->ram[0x%02X] | (n->ram[0x%02X] << 8)); _ea = (uint16_t)(_b + n->y);%s }'
                       % (o, (o + 1) & 0xFF, ' CYC(PAGECROSS(_b, n->y));' if i.pen else ''))
            return 'RD(_ea)'
        raise ValueError(m)

    def store(self, i, v, pre):
        m, o = i.mode, i.operand
        if m == M_ZP: return 'n->ram[0x%02X] = %s;' % (o, v)
        if m == M_ZPX: return 'n->ram[(uint8_t)(0x%02X + n->x)] = %s;' % (o, v)
        if m == M_ZPY: return 'n->ram[(uint8_t)(0x%02X + n->y)] = %s;' % (o, v)
        if m == M_ABS: return self.wr_static(o, v)
        if m == M_ABX: return self.wr_indexed(o, 'x', v)
        if m == M_ABY: return self.wr_indexed(o, 'y', v)
        if m == M_IZX:
            pre.append('{ uint8_t _z = (uint8_t)(0x%02X + n->x); _ea = (uint16_t)(n->ram[_z] | (n->ram[(uint8_t)(_z + 1)] << 8)); }' % o)
            return 'WR(_ea, %s);' % v
        if m == M_IZY:
            pre.append('_ea = (uint16_t)((n->ram[0x%02X] | (n->ram[0x%02X] << 8)) + n->y);' % (o, (o + 1) & 0xFF))
            return 'WR(_ea, %s);' % v
        raise ValueError(m)

    def rmw(self, i, fn):
        m, o = i.mode, i.operand
        if m == M_ACC: return ['n->a = %s(n->a);' % fn]
        if m == M_ZP: return ['n->ram[0x%02X] = %s(n->ram[0x%02X]);' % (o, fn, o)]
        if m == M_ZPX: return ['{ uint8_t _z = (uint8_t)(0x%02X + n->x); n->ram[_z] = %s(n->ram[_z]); }' % (o, fn)]
        if m == M_ABS:
            if o < 0x2000: return ['n->ram[0x%03X] = %s(n->ram[0x%03X]);' % (o & 0x7FF, fn, o & 0x7FF)]
            return ['{ uint8_t _r = %s(RD(0x%04X)); WR(0x%04X, _r); }' % (fn, o, o)]
        if m == M_ABX:
            if o + 0xFF < 0x2000: return ['{ uint16_t _a = (0x%04X + n->x) & 0x7FF; n->ram[_a] = %s(n->ram[_a]); }' % (o, fn)]
            return ['{ uint16_t _a = (uint16_t)(0x%04X + n->x); uint8_t _r = %s(RD(_a)); WR(_a, _r); }' % (o, fn)]
        raise ValueError(m)

    def gen_insn(self, i, labels, bank, win):
        nxt = (i.addr + i.size) & 0xFFFF
        out = ['CYC(%d);' % i.cyc]
        pre = []
        ins = i.ins
        def exit_to(pc): return 'n->pc = 0x%04X; return;' % pc
        def jump_to(pc):
            if pc in labels:
                return 'if (n->cyc >= n->next_event) { n->pc = 0x%04X; return; } goto L_%04X;' % (pc, pc)
            return exit_to(pc)
        body = []
        if ins in ('ADC', 'SBC', 'AND', 'ORA', 'EOR', 'LDA', 'LDX', 'LDY', 'BIT'):
            v = self.operand_read(i, pre)
            body.append('OP_%s(%s);' % (ins, v))
        elif ins in ('CMP', 'CPX', 'CPY'):
            v = self.operand_read(i, pre)
            body.append('OP_CMPR(n->%s, %s);' % ({'CMP': 'a', 'CPX': 'x', 'CPY': 'y'}[ins], v))
        elif ins in ('STA', 'STX', 'STY'):
            body.append(self.store(i, 'n->' + ins[2].lower(), pre))
        elif ins in ('ASL', 'LSR', 'ROL', 'ROR', 'INC', 'DEC'):
            body.extend(self.rmw(i, 'F_' + ins))
        elif ins == 'NOP':
            if i.mode not in (M_IMP, M_IMM):
                body.append('(void)%s;' % self.operand_read(i, pre))
        elif ins in ('INX', 'INY', 'DEX', 'DEY'):
            r = ins[2].lower(); d = '++' if ins[0] == 'I' else '--'
            body.append('n->%s%s; SETNZ(n->%s);' % (r, d, r))
        elif ins in ('TAX', 'TAY', 'TXA', 'TYA', 'TSX'):
            src, dst = {'TAX': ('a', 'x'), 'TAY': ('a', 'y'), 'TXA': ('x', 'a'), 'TYA': ('y', 'a'), 'TSX': ('s', 'x')}[ins]
            body.append('n->%s = n->%s; SETNZ(n->%s);' % (dst, src, dst))
        elif ins == 'TXS': body.append('n->s = n->x;')
        elif ins == 'PHA': body.append('PUSH(n->a);')
        elif ins == 'PHP': body.append('PUSH(GETP(1));')
        elif ins == 'PLA': body.append('n->a = PULL(); SETNZ(n->a);')
        elif ins == 'PLP': body.append('{ uint8_t _p = PULL(); SETP(_p); }')
        elif ins in ('CLC', 'SEC', 'CLI', 'SEI', 'CLD', 'SED', 'CLV'):
            f = {'C': 'fc', 'I': 'fi', 'D': 'fd', 'V': 'fv'}[ins[2]]
            body.append('n->%s = %d;' % (f, 1 if ins[0] == 'S' else 0))
        elif i.mode == M_REL:
            t = (nxt + (i.operand - 256 if i.operand >= 128 else i.operand)) & 0xFFFF
            pen = 2 if (nxt ^ t) & 0xFF00 else 1
            body.append('if (%s) { CYC(%d); %s }' % (BRANCH_COND[ins], pen, jump_to(t)))
        elif ins == 'JMP':
            if i.mode == M_ABS:
                body.append(jump_to(i.operand))
            else:
                p = i.operand
                hi = (p & 0xFF00) | ((p + 1) & 0xFF)
                body.append('n->pc = (uint16_t)(RD(0x%04X) | (RD(0x%04X) << 8)); return;' % (p, hi))
            return out + body
        elif ins == 'JSR':
            r = (i.addr + 2) & 0xFFFF
            body.append('PUSH(0x%02X); PUSH(0x%02X);' % (r >> 8, r & 0xFF))
            body.append(exit_to(i.operand))
            return out + body
        elif ins == 'RTS':
            body.append('{ uint16_t _lo = PULL(); uint16_t _hi = PULL(); n->pc = (uint16_t)(((_hi << 8) | _lo) + 1); } return;')
            return out + body
        elif ins == 'RTI':
            body.append('{ uint8_t _p = PULL(); SETP(_p); uint16_t _lo = PULL(); uint16_t _hi = PULL(); n->pc = (uint16_t)((_hi << 8) | _lo); } return;')
            return out + body
        elif ins == 'BRK':
            r = (i.addr + 2) & 0xFFFF
            body.append('PUSH(0x%02X); PUSH(0x%02X); PUSH(GETP(1)); n->fi = 1; n->pc = (uint16_t)(RD(0xFFFE) | (RD(0xFFFF) << 8)); return;' % (r >> 8, r & 0xFF))
            return out + body
        else:
            raise ValueError(ins)
        return out + pre + body + ['if (n->cyc >= n->next_event) { %s }' % exit_to(nxt)]

    def generate(self, path):
        o = []
        o.append('// AUTO-GENERATED by Tools/recompile.py from your ROM (PRG CRC32 %08X). Do not edit.' % self.rom.crc)
        o.append('#include "nes_internal.h"')
        o.append('#if defined(__clang__) || defined(__GNUC__)')
        o.append('#pragma GCC diagnostic ignored "-Wunused-label"')
        o.append('#pragma GCC diagnostic ignored "-Wunused-variable"')
        o.append('#endif')
        names = {}
        for key in sorted(self.blocks):
            bank, win, start = key
            names[key] = ('R%d_%04X' % (bank, start)) if win == 2 else ('B%d_%d_%04X' % (bank, win, start))
            o.append('static void %s(NES *n);' % names[key])
        o.append('')
        n_insn = 0
        for key in sorted(self.blocks):
            bank, win, start = key
            insns = self.blocks[key]
            labels = {i.addr for i in insns}
            if win == 2:
                end = insns[-1].addr + insns[-1].size
                raw = bytes(self.rom.byte(bank, win, a) for a in range(start, end))
                o.append('static const uint8_t K_%s[%d] = {%s};' % (names[key], len(raw), ','.join('0x%02X' % b for b in raw)))
            o.append('static void %s(NES *n) {' % names[key])
            if win == 2:
                o.append('  RAM_GUARD(0x%04X, K_%s, %d);  // PRG-RAM code: verify bytes still match the ROM copy' % (start - 0x6000, names[key], len(raw)))
            o.append('  uint16_t _ea; (void)_ea;')
            o.append('  switch (n->pc) {')
            for i in insns:
                o.append('    case 0x%04X: goto L_%04X;' % (i.addr, i.addr))
            o.append('    default: return;')
            o.append('  }')
            for i in insns:
                n_insn += 1
                o.append('L_%04X: ; // %s' % (i.addr, self.disasm(i)))
                for line in self.gen_insn(i, labels, bank, win):
                    o.append('  ' + line)
            o.append('  n->pc = 0x%04X; return;' % ((insns[-1].addr + insns[-1].size) & 0xFFFF))
            o.append('}')
            o.append('')
        # dispatch tables
        per = {}
        for (bank, win, addr), key in self.owner.items():
            per.setdefault((bank, win), {})[addr] = names[key]
        ramtab = {}
        for (bank, win) in sorted(per):
            if win == 2:
                ramtab.update(per[(bank, win)])
                continue
            o.append('static const recomp_fn T_%d_%d[16384] = {' % (bank, win))
            base = 0x8000 + win * 0x4000
            for addr in sorted(per[(bank, win)]):
                o.append('  [0x%04X] = %s,' % (addr - base, per[(bank, win)][addr]))
            o.append('};')
        o.append('static const recomp_fn T_RAM[8192] = {')
        for addr in sorted(ramtab):
            o.append('  [0x%04X] = %s,' % (addr - 0x6000, ramtab[addr]))
        o.append('  [0] = 0 };')
        o.append('static const recomp_fn *const TABLES[16][2] = {')
        for bank in range(16):
            row = []
            for win in (0, 1):
                row.append('T_%d_%d' % (bank, win) if (bank, win) in per else '0')
            o.append('  { %s },' % ', '.join(row))
        o.append('};')
        o.append('''
recomp_fn recomp_lookup(NES *n, uint16_t pc) {
    if (pc < 0x8000) return (pc >= 0x6000) ? T_RAM[pc - 0x6000] : 0;
    int w = (pc >> 14) & 1;
    const recomp_fn *t = TABLES[n->prg_bank[w] & 15][w];
    return t ? t[pc & 0x3FFF] : 0;
}
int nes_recomp_available(void) { return 1; }
uint32_t nes_recomp_rom_crc(void) { return 0x%08Xu; }
''' % self.rom.crc)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, 'w') as f:
            f.write('\n'.join(o))
        return n_insn

    @staticmethod
    def disasm(i):
        o = i.operand
        fm = {M_IMP: '', M_ACC: ' A', M_IMM: ' #$%02X', M_ZP: ' $%02X', M_ZPX: ' $%02X,X', M_ZPY: ' $%02X,Y',
              M_ABS: ' $%04X', M_ABX: ' $%04X,X', M_ABY: ' $%04X,Y', M_IND: ' ($%04X)', M_IZX: ' ($%02X,X)',
              M_IZY: ' ($%02X),Y', M_REL: ' $%02X'}[i.mode]
        return i.ins + (fm % o if '%' in fm else fm)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rom', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--overlay', action='append', default=[],
                    help='bank:romoffset:ramaddr:length (hex offsets) of code copied to PRG-RAM')
    ap.add_argument('--coverage', action='append', default=[],
                    help='file or directory of "bank window addr" lines (runtime misses / shipped seeds)')
    a = ap.parse_args()
    rom = Rom(a.rom)
    rc = Recompiler(rom)
    for vec in (0xFFFA, 0xFFFC, 0xFFFE):
        t = rom.byte(rom.last, 1, vec) | (rom.byte(rom.last, 1, vec + 1) << 8)
        c = target_ctx(rom, rom.last, 1, t)
        if c: rc.enqueue(c[0], c[1], t)
    for ov in a.overlay:
        b, off, ram, ln = ov.split(':')
        rom.overlays.append((int(b), int(off, 16), int(ram, 16), int(ln)))
    nseeds = 0
    files = []
    for c in a.coverage:
        files += sorted(glob.glob(os.path.join(c, '*.txt'))) if os.path.isdir(c) else [c]
    for fn in files:
        if not os.path.exists(fn): continue
        for line in open(fn):
            p = line.split()
            if p and p[0] == 'overlay' and len(p) == 5:
                ov = (int(p[1]), int(p[2], 16), int(p[3], 16), int(p[4]))
                if ov not in rom.overlays and ov[0] < rom.banks: rom.overlays.append(ov)
                continue
            if len(p) != 3 or line.startswith('#'): continue
            bank, win, addr = int(p[0]), int(p[1]), int(p[2], 16)
            if win == 2:
                c = target_ctx(rom, 0, 2, addr)
                if c: rc.enqueue(c[0], 2, addr); nseeds += 1
            elif bank < rom.banks:
                rc.enqueue(bank, win, addr); nseeds += 1
    rc.run()
    n = rc.generate(a.out)
    print('bank-switch helpers: %s; jump-table helpers: %s' % (', '.join('$%04X' % x for x in sorted(rc.switchers)),
          ', '.join('$%04X' % x for x in sorted(rc.tablejumps))))
    print('recompiled %d blocks / %d instructions (PRG CRC %08X, %d coverage seeds) -> %s'
          % (len(rc.blocks), n, rom.crc, nseeds, a.out))


if __name__ == '__main__':
    main()
