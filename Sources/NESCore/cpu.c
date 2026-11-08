// cpu.c — reference 6502 (2A03) interpreter. Used as the fallback path for any
// code the static recompiler did not translate (RAM code, unseen indirect jump
// targets) and as the oracle for differential testing of generated code.
#include "nes_internal.h"
#include "cpu_table.h"

void cpu_interp_step(NES *n) {
    uint16_t pc = n->pc;
    uint8_t op = RD(pc);
    const OpInfo *oi = &OPS[op];
    uint16_t ea = 0; uint8_t pen = 0;
    uint16_t next = (uint16_t)(pc + (oi->len ? oi->len : 1));  // unknown opcodes: 1-byte NOP

    switch (oi->mode) {
        case M_IMP: case M_ACC: break;
        case M_IMM: ea = (uint16_t)(pc + 1); break;
        case M_ZP:  ea = RD(pc + 1); break;
        case M_ZPX: ea = (uint8_t)(RD(pc + 1) + n->x); break;
        case M_ZPY: ea = (uint8_t)(RD(pc + 1) + n->y); break;
        case M_ABS: ea = (uint16_t)(RD(pc + 1) | (RD(pc + 2) << 8)); break;
        case M_ABX: { uint16_t b = (uint16_t)(RD(pc + 1) | (RD(pc + 2) << 8)); ea = (uint16_t)(b + n->x); pen = PAGECROSS(b, n->x); break; }
        case M_ABY: { uint16_t b = (uint16_t)(RD(pc + 1) | (RD(pc + 2) << 8)); ea = (uint16_t)(b + n->y); pen = PAGECROSS(b, n->y); break; }
        case M_IND: { uint16_t p = (uint16_t)(RD(pc + 1) | (RD(pc + 2) << 8));
                      ea = (uint16_t)(RD(p) | (RD((p & 0xFF00) | ((p + 1) & 0xFF)) << 8)); break; }
        case M_IZX: { uint8_t z = (uint8_t)(RD(pc + 1) + n->x); ea = (uint16_t)(ZP(z) | (ZP(z + 1) << 8)); break; }
        case M_IZY: { uint8_t z = RD(pc + 1); uint16_t b = (uint16_t)(ZP(z) | (ZP(z + 1) << 8));
                      ea = (uint16_t)(b + n->y); pen = PAGECROSS(b, n->y); break; }
        case M_REL: { int8_t r = (int8_t)RD(pc + 1); ea = (uint16_t)(next + r); break; }
    }
    CYC((oi->cyc ? oi->cyc : 2) + (oi->pen ? pen : 0));
    n->pc = next;

#define V() RD(ea)
#define BR(c) do { if (c) { CYC(1 + (((next ^ ea) & 0xFF00) ? 1 : 0)); n->pc = ea; } } while (0)
#define RMW(F) do { if (oi->mode == M_ACC) n->a = F(n->a); else { uint8_t _o = RD(ea); uint8_t _r = F(_o); WR(ea, _r); } } while (0)
    switch (oi->ins) {
        case I_ADC: OP_ADC(V()); break;
        case I_SBC: OP_SBC(V()); break;
        case I_AND: OP_AND(V()); break;
        case I_ORA: OP_ORA(V()); break;
        case I_EOR: OP_EOR(V()); break;
        case I_CMP: OP_CMPR(n->a, V()); break;
        case I_CPX: OP_CMPR(n->x, V()); break;
        case I_CPY: OP_CMPR(n->y, V()); break;
        case I_BIT: OP_BIT(V()); break;
        case I_LDA: OP_LDA(V()); break;
        case I_LDX: OP_LDX(V()); break;
        case I_LDY: OP_LDY(V()); break;
        case I_STA: WR(ea, n->a); break;
        case I_STX: WR(ea, n->x); break;
        case I_STY: WR(ea, n->y); break;
        case I_ASL: RMW(F_ASL); break;
        case I_LSR: RMW(F_LSR); break;
        case I_ROL: RMW(F_ROL); break;
        case I_ROR: RMW(F_ROR); break;
        case I_INC: { uint8_t r = F_INC(RD(ea)); WR(ea, r); break; }
        case I_DEC: { uint8_t r = F_DEC(RD(ea)); WR(ea, r); break; }
        case I_INX: n->x++; SETNZ(n->x); break;
        case I_INY: n->y++; SETNZ(n->y); break;
        case I_DEX: n->x--; SETNZ(n->x); break;
        case I_DEY: n->y--; SETNZ(n->y); break;
        case I_TAX: n->x = n->a; SETNZ(n->x); break;
        case I_TAY: n->y = n->a; SETNZ(n->y); break;
        case I_TXA: n->a = n->x; SETNZ(n->a); break;
        case I_TYA: n->a = n->y; SETNZ(n->a); break;
        case I_TSX: n->x = n->s; SETNZ(n->x); break;
        case I_TXS: n->s = n->x; break;
        case I_PHA: PUSH(n->a); break;
        case I_PHP: PUSH(GETP(1)); break;
        case I_PLA: n->a = PULL(); SETNZ(n->a); break;
        case I_PLP: { uint8_t p = PULL(); SETP(p); break; }
        case I_CLC: n->fc = 0; break;
        case I_SEC: n->fc = 1; break;
        case I_CLI: n->fi = 0; break;
        case I_SEI: n->fi = 1; break;
        case I_CLD: n->fd = 0; break;
        case I_SED: n->fd = 1; break;
        case I_CLV: n->fv = 0; break;
        case I_BCC: BR(COND_BCC); break;
        case I_BCS: BR(COND_BCS); break;
        case I_BNE: BR(COND_BNE); break;
        case I_BEQ: BR(COND_BEQ); break;
        case I_BPL: BR(COND_BPL); break;
        case I_BMI: BR(COND_BMI); break;
        case I_BVC: BR(COND_BVC); break;
        case I_BVS: BR(COND_BVS); break;
        case I_JMP: n->pc = ea; break;
        case I_JSR: { uint16_t r = (uint16_t)(next - 1); PUSH(r >> 8); PUSH(r & 0xFF); n->pc = ea; break; }
        case I_RTS: { uint16_t lo = PULL(); uint16_t hi = PULL(); n->pc = (uint16_t)(((hi << 8) | lo) + 1); break; }
        case I_RTI: { uint8_t p = PULL(); SETP(p); uint16_t lo = PULL(); uint16_t hi = PULL(); n->pc = (uint16_t)((hi << 8) | lo); break; }
        case I_BRK: { uint16_t r = (uint16_t)(pc + 2); PUSH(r >> 8); PUSH(r & 0xFF); PUSH(GETP(1)); n->fi = 1;
                      n->pc = (uint16_t)(RD(0xFFFE) | (RD(0xFFFF) << 8)); break; }
        case I_NOP: if (oi->mode != M_IMP && oi->mode != M_IMM) (void)V(); break;
        default: break;
    }
#undef V
#undef BR
#undef RMW
}
