# TODO : hex
type
  Op* {.pure.} = enum
    STOP = 0x0,    # 0
    ADD,           # 1
    MUL,           # 2
    SUB,           # 3
    DIV,           # 4
    SDIV,          # 5
    MOD,           # 6
    SMOD,          # 7
    ADDMOD,        # 8
    MULMOD,        # 9
    EXP,           # 10
    SIGNEXTEND,    # 11

    LT = 0x10,     # 16
    GT,            # 17
    SLT,           # 18
    SGT,           # 19
    EQ,            # 20
    ISZERO,        # 21
    AND,           # 22
    OR,            # 23
    XOR,           # 24
    NOT,           # 25
    BYTE,          # 26

    SHA3 = 0x20,   # 32
    
    ADDRESS = 0x30,# 48
    BALANCE,       # 49
    ORIGIN,        # 50

    CALLER,        # 51
    CALLVALUE,     # 52
    CALLDATALOAD,  # 53
    CALLDATASIZE,  # 54
    CALLDATACOPY,  # 55

    CODESIZE,      # 56
    CODECOPY,      # 57

    GASPRICE,      # 58

    EXTCODESIZE,   # 59
    EXTCODECOPY,   # 60

    RETURNDATASIZE, # 61
    RETURNDATACOPY, # 62

    BLOCKHASH = 0x40,# 64

    COINBASE,      # 65

    TIMESTAMP,     # 66

    NUMBER,        # 67

    DIFFICULTY,    # 68

    GASLIMIT,      # 69
    
    POP = 0x50,    # 80

    MLOAD,         # 81
    MSTORE,        # 82
    MSTORE8        # 83

    SLOAD,         # 84
    SSTORE,        # 85

    JUMP,          # 86
    JUMPI,         # 87

    PC,            # 88

    MSIZE,         # 89

    GAS,           # 90

    JUMPDEST,      # 91
    
    PUSH1 = 0x60,  # 96
    PUSH2,         # 97
    PUSH3,         # 98
    PUSH4,         # 99
    PUSH5,         # 100
    PUSH6,         # 101
    PUSH7,         # 102
    PUSH8,         # 103
    PUSH9,         # 104
    PUSH10,        # 105
    PUSH11,        # 106
    PUSH12,        # 107
    PUSH13,        # 108
    PUSH14,        # 109
    PUSH15,        # 110
    PUSH16,        # 111
    PUSH17,        # 112
    PUSH18,        # 113
    PUSH19,        # 114
    PUSH20,        # 115
    PUSH21,        # 116
    PUSH22,        # 117
    PUSH23,        # 118
    PUSH24,        # 119
    PUSH25,        # 120
    PUSH26,        # 121
    PUSH27,        # 122
    PUSH28,        # 123
    PUSH29,        # 124
    PUSH30,        # 125
    PUSH31,        # 126
    PUSH32,        # 127
    DUP1,          # 128
    DUP2,          # 129
    DUP3,          # 130
    DUP4,          # 131
    DUP5,          # 132
    DUP6,          # 133
    DUP7,          # 134
    DUP8,          # 135
    DUP9,          # 136
    DUP10,         # 137
    DUP11,         # 138
    DUP12,         # 139
    DUP13,         # 140
    DUP14,         # 141
    DUP15,         # 142
    DUP16,         # 143
    SWAP1,         # 144
    SWAP2,         # 145
    SWAP3,         # 146
    SWAP4,         # 147
    SWAP5,         # 148
    SWAP6,         # 149
    SWAP7,         # 150
    SWAP8,         # 151
    SWAP9,         # 152
    SWAP10,        # 153
    SWAP11,        # 154
    SWAP12,        # 155
    SWAP13,        # 156
    SWAP14,        # 157
    SWAP15,        # 158
    SWAP16,        # 159
    LOG0,          # 160
    LOG1,          # 161
    LOG2,          # 162
    LOG3,          # 163
    LOG4,          # 164
    CREATE = 0xf0, # 240
    CALL,          # 241
    CALLCODE,      # 242
    RETURN,        # 243
    DELEGATECALL,  # 244
    STATICCALL = 0xfa,# 250
    REVERT = 0xfd, # 253
    SELFDESTRUCT = 0xff,# 255
    INVALID        # invalid

