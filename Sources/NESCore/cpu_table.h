// cpu_table.h — 6502 opcode table (official opcodes + unofficial NOPs).
// Mirrored in Tools/recompile.py; differential tests keep both in sync.
#ifndef CPU_TABLE_H
#define CPU_TABLE_H
#include <stdint.h>

enum { M_IMP, M_ACC, M_IMM, M_ZP, M_ZPX, M_ZPY, M_ABS, M_ABX, M_ABY, M_IND, M_IZX, M_IZY, M_REL };
enum {
    I_NOP, I_ADC, I_AND, I_ASL, I_BCC, I_BCS, I_BEQ, I_BIT, I_BMI, I_BNE, I_BPL, I_BRK, I_BVC, I_BVS,
    I_CLC, I_CLD, I_CLI, I_CLV, I_CMP, I_CPX, I_CPY, I_DEC, I_DEX, I_DEY, I_EOR, I_INC, I_INX, I_INY,
    I_JMP, I_JSR, I_LDA, I_LDX, I_LDY, I_LSR, I_ORA, I_PHA, I_PHP, I_PLA, I_PLP, I_ROL, I_ROR, I_RTI,
    I_RTS, I_SBC, I_SEC, I_SED, I_SEI, I_STA, I_STX, I_STY, I_TAX, I_TAY, I_TSX, I_TXA, I_TXS, I_TYA
};

typedef struct { uint8_t ins, mode, len, cyc, pen; } OpInfo;

#define O(op, i, m, l, c, p) [op] = { i, m, l, c, p }
static const OpInfo OPS[256] = {
    O(0x69,I_ADC,M_IMM,2,2,0), O(0x65,I_ADC,M_ZP,2,3,0), O(0x75,I_ADC,M_ZPX,2,4,0), O(0x6D,I_ADC,M_ABS,3,4,0),
    O(0x7D,I_ADC,M_ABX,3,4,1), O(0x79,I_ADC,M_ABY,3,4,1), O(0x61,I_ADC,M_IZX,2,6,0), O(0x71,I_ADC,M_IZY,2,5,1),
    O(0x29,I_AND,M_IMM,2,2,0), O(0x25,I_AND,M_ZP,2,3,0), O(0x35,I_AND,M_ZPX,2,4,0), O(0x2D,I_AND,M_ABS,3,4,0),
    O(0x3D,I_AND,M_ABX,3,4,1), O(0x39,I_AND,M_ABY,3,4,1), O(0x21,I_AND,M_IZX,2,6,0), O(0x31,I_AND,M_IZY,2,5,1),
    O(0x0A,I_ASL,M_ACC,1,2,0), O(0x06,I_ASL,M_ZP,2,5,0), O(0x16,I_ASL,M_ZPX,2,6,0), O(0x0E,I_ASL,M_ABS,3,6,0), O(0x1E,I_ASL,M_ABX,3,7,0),
    O(0x90,I_BCC,M_REL,2,2,0), O(0xB0,I_BCS,M_REL,2,2,0), O(0xF0,I_BEQ,M_REL,2,2,0), O(0x30,I_BMI,M_REL,2,2,0),
    O(0xD0,I_BNE,M_REL,2,2,0), O(0x10,I_BPL,M_REL,2,2,0), O(0x50,I_BVC,M_REL,2,2,0), O(0x70,I_BVS,M_REL,2,2,0),
    O(0x24,I_BIT,M_ZP,2,3,0), O(0x2C,I_BIT,M_ABS,3,4,0),
    O(0x00,I_BRK,M_IMP,1,7,0),
    O(0x18,I_CLC,M_IMP,1,2,0), O(0xD8,I_CLD,M_IMP,1,2,0), O(0x58,I_CLI,M_IMP,1,2,0), O(0xB8,I_CLV,M_IMP,1,2,0),
    O(0xC9,I_CMP,M_IMM,2,2,0), O(0xC5,I_CMP,M_ZP,2,3,0), O(0xD5,I_CMP,M_ZPX,2,4,0), O(0xCD,I_CMP,M_ABS,3,4,0),
    O(0xDD,I_CMP,M_ABX,3,4,1), O(0xD9,I_CMP,M_ABY,3,4,1), O(0xC1,I_CMP,M_IZX,2,6,0), O(0xD1,I_CMP,M_IZY,2,5,1),
    O(0xE0,I_CPX,M_IMM,2,2,0), O(0xE4,I_CPX,M_ZP,2,3,0), O(0xEC,I_CPX,M_ABS,3,4,0),
    O(0xC0,I_CPY,M_IMM,2,2,0), O(0xC4,I_CPY,M_ZP,2,3,0), O(0xCC,I_CPY,M_ABS,3,4,0),
    O(0xC6,I_DEC,M_ZP,2,5,0), O(0xD6,I_DEC,M_ZPX,2,6,0), O(0xCE,I_DEC,M_ABS,3,6,0), O(0xDE,I_DEC,M_ABX,3,7,0),
    O(0xCA,I_DEX,M_IMP,1,2,0), O(0x88,I_DEY,M_IMP,1,2,0),
    O(0x49,I_EOR,M_IMM,2,2,0), O(0x45,I_EOR,M_ZP,2,3,0), O(0x55,I_EOR,M_ZPX,2,4,0), O(0x4D,I_EOR,M_ABS,3,4,0),
    O(0x5D,I_EOR,M_ABX,3,4,1), O(0x59,I_EOR,M_ABY,3,4,1), O(0x41,I_EOR,M_IZX,2,6,0), O(0x51,I_EOR,M_IZY,2,5,1),
    O(0xE6,I_INC,M_ZP,2,5,0), O(0xF6,I_INC,M_ZPX,2,6,0), O(0xEE,I_INC,M_ABS,3,6,0), O(0xFE,I_INC,M_ABX,3,7,0),
    O(0xE8,I_INX,M_IMP,1,2,0), O(0xC8,I_INY,M_IMP,1,2,0),
    O(0x4C,I_JMP,M_ABS,3,3,0), O(0x6C,I_JMP,M_IND,3,5,0), O(0x20,I_JSR,M_ABS,3,6,0),
    O(0xA9,I_LDA,M_IMM,2,2,0), O(0xA5,I_LDA,M_ZP,2,3,0), O(0xB5,I_LDA,M_ZPX,2,4,0), O(0xAD,I_LDA,M_ABS,3,4,0),
    O(0xBD,I_LDA,M_ABX,3,4,1), O(0xB9,I_LDA,M_ABY,3,4,1), O(0xA1,I_LDA,M_IZX,2,6,0), O(0xB1,I_LDA,M_IZY,2,5,1),
    O(0xA2,I_LDX,M_IMM,2,2,0), O(0xA6,I_LDX,M_ZP,2,3,0), O(0xB6,I_LDX,M_ZPY,2,4,0), O(0xAE,I_LDX,M_ABS,3,4,0), O(0xBE,I_LDX,M_ABY,3,4,1),
    O(0xA0,I_LDY,M_IMM,2,2,0), O(0xA4,I_LDY,M_ZP,2,3,0), O(0xB4,I_LDY,M_ZPX,2,4,0), O(0xAC,I_LDY,M_ABS,3,4,0), O(0xBC,I_LDY,M_ABX,3,4,1),
    O(0x4A,I_LSR,M_ACC,1,2,0), O(0x46,I_LSR,M_ZP,2,5,0), O(0x56,I_LSR,M_ZPX,2,6,0), O(0x4E,I_LSR,M_ABS,3,6,0), O(0x5E,I_LSR,M_ABX,3,7,0),
    O(0xEA,I_NOP,M_IMP,1,2,0),
    O(0x09,I_ORA,M_IMM,2,2,0), O(0x05,I_ORA,M_ZP,2,3,0), O(0x15,I_ORA,M_ZPX,2,4,0), O(0x0D,I_ORA,M_ABS,3,4,0),
    O(0x1D,I_ORA,M_ABX,3,4,1), O(0x19,I_ORA,M_ABY,3,4,1), O(0x01,I_ORA,M_IZX,2,6,0), O(0x11,I_ORA,M_IZY,2,5,1),
    O(0x48,I_PHA,M_IMP,1,3,0), O(0x08,I_PHP,M_IMP,1,3,0), O(0x68,I_PLA,M_IMP,1,4,0), O(0x28,I_PLP,M_IMP,1,4,0),
    O(0x2A,I_ROL,M_ACC,1,2,0), O(0x26,I_ROL,M_ZP,2,5,0), O(0x36,I_ROL,M_ZPX,2,6,0), O(0x2E,I_ROL,M_ABS,3,6,0), O(0x3E,I_ROL,M_ABX,3,7,0),
    O(0x6A,I_ROR,M_ACC,1,2,0), O(0x66,I_ROR,M_ZP,2,5,0), O(0x76,I_ROR,M_ZPX,2,6,0), O(0x6E,I_ROR,M_ABS,3,6,0), O(0x7E,I_ROR,M_ABX,3,7,0),
    O(0x40,I_RTI,M_IMP,1,6,0), O(0x60,I_RTS,M_IMP,1,6,0),
    O(0xE9,I_SBC,M_IMM,2,2,0), O(0xE5,I_SBC,M_ZP,2,3,0), O(0xF5,I_SBC,M_ZPX,2,4,0), O(0xED,I_SBC,M_ABS,3,4,0),
    O(0xFD,I_SBC,M_ABX,3,4,1), O(0xF9,I_SBC,M_ABY,3,4,1), O(0xE1,I_SBC,M_IZX,2,6,0), O(0xF1,I_SBC,M_IZY,2,5,1),
    O(0xEB,I_SBC,M_IMM,2,2,0),
    O(0x38,I_SEC,M_IMP,1,2,0), O(0xF8,I_SED,M_IMP,1,2,0), O(0x78,I_SEI,M_IMP,1,2,0),
    O(0x85,I_STA,M_ZP,2,3,0), O(0x95,I_STA,M_ZPX,2,4,0), O(0x8D,I_STA,M_ABS,3,4,0), O(0x9D,I_STA,M_ABX,3,5,0),
    O(0x99,I_STA,M_ABY,3,5,0), O(0x81,I_STA,M_IZX,2,6,0), O(0x91,I_STA,M_IZY,2,6,0),
    O(0x86,I_STX,M_ZP,2,3,0), O(0x96,I_STX,M_ZPY,2,4,0), O(0x8E,I_STX,M_ABS,3,4,0),
    O(0x84,I_STY,M_ZP,2,3,0), O(0x94,I_STY,M_ZPX,2,4,0), O(0x8C,I_STY,M_ABS,3,4,0),
    O(0xAA,I_TAX,M_IMP,1,2,0), O(0xA8,I_TAY,M_IMP,1,2,0), O(0xBA,I_TSX,M_IMP,1,2,0),
    O(0x8A,I_TXA,M_IMP,1,2,0), O(0x9A,I_TXS,M_IMP,1,2,0), O(0x98,I_TYA,M_IMP,1,2,0),
    // unofficial NOPs (length-correct)
    O(0x1A,I_NOP,M_IMP,1,2,0), O(0x3A,I_NOP,M_IMP,1,2,0), O(0x5A,I_NOP,M_IMP,1,2,0), O(0x7A,I_NOP,M_IMP,1,2,0),
    O(0xDA,I_NOP,M_IMP,1,2,0), O(0xFA,I_NOP,M_IMP,1,2,0),
    O(0x80,I_NOP,M_IMM,2,2,0), O(0x82,I_NOP,M_IMM,2,2,0), O(0x89,I_NOP,M_IMM,2,2,0), O(0xC2,I_NOP,M_IMM,2,2,0), O(0xE2,I_NOP,M_IMM,2,2,0),
    O(0x04,I_NOP,M_ZP,2,3,0), O(0x44,I_NOP,M_ZP,2,3,0), O(0x64,I_NOP,M_ZP,2,3,0),
    O(0x14,I_NOP,M_ZPX,2,4,0), O(0x34,I_NOP,M_ZPX,2,4,0), O(0x54,I_NOP,M_ZPX,2,4,0), O(0x74,I_NOP,M_ZPX,2,4,0),
    O(0xD4,I_NOP,M_ZPX,2,4,0), O(0xF4,I_NOP,M_ZPX,2,4,0),
    O(0x0C,I_NOP,M_ABS,3,4,0),
    O(0x1C,I_NOP,M_ABX,3,4,1), O(0x3C,I_NOP,M_ABX,3,4,1), O(0x5C,I_NOP,M_ABX,3,4,1), O(0x7C,I_NOP,M_ABX,3,4,1),
    O(0xDC,I_NOP,M_ABX,3,4,1), O(0xFC,I_NOP,M_ABX,3,4,1),
};
#undef O
// Any opcode not listed decodes as {I_NOP, M_IMP, len 0}; fix up len at use.
#endif
