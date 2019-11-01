import macro_assembler, unittest2

proc opBitMain*() =
  suite "Bitwise Opcodes":
    setup:
      let (blockNumber, chainDB) = initDatabase()

    assembler: # AND OP
      title: "AND_1"
      code:
        PUSH1 "0x0A"
        PUSH1 "0x0A"
        AND
      stack: "0x000000000000000000000000000000000000000000000000000000000000000A"

    assembler: # AND OP
      title: "AND_2"
      code:
        PUSH1 "0xC0"
        PUSH1 "0x0A"
        AND
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # AND OP mal data
      title: "AND_3"
      code:
        PUSH1 "0xC0"
        AND
      success: false
      stack: "0xC0"

    assembler: # OR OP
      title: "OR_1"
      code:
        PUSH1 "0xF0"
        PUSH1 "0x0F"
        OR
      stack: "0x00000000000000000000000000000000000000000000000000000000000000FF"

    assembler: # OR OP
      title: "OR_2"
      code:
        PUSH1 "0xC3"
        PUSH1 "0x3C"
        OR
      stack: "0x00000000000000000000000000000000000000000000000000000000000000FF"

    assembler: # OR OP mal data
      title: "OR_3"
      code:
        PUSH1 "0xC0"
        OR
      success: false
      stack: "0xC0"

    assembler: # XOR OP
      title: "XOR_1"
      code:
        PUSH1 "0xFF"
        PUSH1 "0xFF"
        XOR
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # XOR OP
      title: "XOR_2"
      code:
        PUSH1 "0x0F"
        PUSH1 "0xF0"
        XOR
      stack: "0x00000000000000000000000000000000000000000000000000000000000000FF"

    assembler: # XOR OP mal data
      title: "XOR_3"
      code:
        PUSH1 "0xC0"
        XOR
      success: false
      stack: "0xC0"

    assembler: # BYTE OP
      title: "BYTE_1"
      code:
        PUSH6 "0xAABBCCDDEEFF"
        PUSH1 "0x1E"
        BYTE
      stack: "0x00000000000000000000000000000000000000000000000000000000000000EE"

    assembler: # BYTE OP
      title: "BYTE_2"
      code:
        PUSH6 "0xAABBCCDDEEFF"
        PUSH1 "0x20"
        BYTE
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # BYTE OP
      title: "BYTE_3"
      code:
        PUSH6 "0xAABBCCDDEE3A"
        PUSH1 "0x1F"
        BYTE
      stack: "0x000000000000000000000000000000000000000000000000000000000000003A"

    assembler: # BYTE OP mal data
      title: "BYTE_4"
      code:
        PUSH6 "0xAABBCCDDEE3A"
        BYTE
      success: false
      stack: "0xAABBCCDDEE3A"

    assembler: # SHL OP
      title: "SHL_1"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH1 "0x00"
        SHL
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SHL OP
      title: "SHL_2"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH1 "0x01"
        SHL
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # SHL OP
      title: "SHL_3"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH1 "0xff"
        SHL
      fork: constantinople
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHL OP
      title: "SHL_4"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH2 "0x0100"
        SHL
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHL OP
      title: "SHL_5"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH2 "0x0101"
        SHL
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHL OP
      title: "SHL_6"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0x00"
        SHL
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SHL OP
      title: "SHL_7"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0x01"
        SHL
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"

    assembler: # SHL OP
      title: "SHL_8"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0xff"
        SHL
      fork: constantinople
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHL OP
      title: "SHL_9"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH2 "0x0100"
        SHL
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHL OP
      title: "SHL_10"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0x01"
        SHL
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHL OP
      title: "SHL_11"
      code:
        PUSH32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0x01"
        SHL
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"

    assembler: # SHR OP
      title: "SHR_1"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH1 "0x00"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SHR OP
      title: "SHR_2"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH1 "0x01"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHR OP
      title: "SHR_3"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0x01"
        SHR
      fork: constantinople
      stack: "0x4000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHR OP
      title: "SHR_4"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0xff"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SHR OP
      title: "SHR_5"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH2 "0x0100"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHR OP
      title: "SHR_6"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH2 "0x0101"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHR OP
      title: "SHR_7"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0x00"
        SHR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SHR OP
      title: "SHR_8"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0x01"
        SHR
      fork: constantinople
      stack: "0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SHR OP
      title: "SHR_9"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0xff"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SHR OP
      title: "SHR_10"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH2 "0x0100"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SHR OP
      title: "SHR_11"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0x01"
        SHR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SAR OP
      title: "SAR_1"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH1 "0x00"
        SAR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SAR OP
      title: "SAR_2"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        PUSH1 "0x01"
        SAR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SAR OP
      title: "SAR_3"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0x01"
        SAR
      fork: constantinople
      stack: "0xC000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SAR OP
      title: "SAR_4"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0xff"
        SAR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SAR OP
      title: "SAR_5"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH2 "0x0100"
        SAR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SAR OP
      title: "SAR_6"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        PUSH2 "0x0101"
        SAR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SAR OP
      title: "SAR_7"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0x00"
        SAR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SAR OP
      title: "SAR_8"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0x01"
        SAR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SAR OP
      title: "SAR_9"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0xff"
        SAR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SAR OP
      title: "SAR_10"
      code:
        PUSH32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH2 "0x0100"
        SAR
      fork: constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SAR OP
      title: "SAR_11"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0x01"
        SAR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SAR OP
      title: "SAR_12"
      code:
        PUSH32 "0x4000000000000000000000000000000000000000000000000000000000000000"
        PUSH1 "0xfe"
        SAR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SAR OP
      title: "SAR_13"
      code:
        PUSH32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0xf8"
        SAR
      fork: constantinople
      stack: "0x000000000000000000000000000000000000000000000000000000000000007F"

    assembler: # SAR OP
      title: "SAR_14"
      code:
        PUSH32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0xfe"
        SAR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SAR OP
      title: "SAR_15"
      code:
        PUSH32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH1 "0xff"
        SAR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SAR OP
      title: "SAR_16"
      code:
        PUSH32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        PUSH2 "0x0100"
        SAR
      fork: constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # ISZERO OP
      title: "ISZERO_1"
      code:
        PUSH1 "0x00"
        ISZERO
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # ISZERO OP
      title: "ISZERO_2"
      code:
        PUSH1 "0x2A"
        ISZERO
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # ISZERO OP mal data
      title: "ISZERO_3"
      code: ISZERO
      success: false

    assembler: # EQ OP
      title: "EQ_1"
      code:
        PUSH1 "0x2A"
        PUSH1 "0x2A"
        EQ
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # EQ OP
      title: "EQ_2"
      code:
        PUSH3 "0x2A3B4C"
        PUSH3 "0x2A3B4C"
        EQ
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # EQ OP
      title: "EQ_3"
      code:
        PUSH3 "0x2A3B5C"
        PUSH3 "0x2A3B4C"
        EQ
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # EQ OP mal data
      title: "EQ_4"
      code:
        PUSH3 "0x2A3B4C"
        EQ
      success: false
      stack: "0x2A3B4C"

    assembler: # GT OP
      title: "GT_1"
      code:
        PUSH1 "0x01"
        PUSH1 "0x02"
        GT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # GT OP
      title: "GT_2"
      code:
        PUSH1 "0x01"
        PUSH2 "0x0F00"
        GT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # GT OP
      title: "GT_3"
      code:
        PUSH4 "0x01020304"
        PUSH2 "0x0F00"
        GT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # GT OP mal data
      title: "GT_4"
      code:
        PUSH3 "0x2A3B4C"
        GT
      success: false
      stack: "0x2A3B4C"

    assembler: # SGT OP
      title: "SGT_1"
      code:
        PUSH1 "0x01"
        PUSH1 "0x02"
        SGT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SGT OP
      title: "SGT_2"
      code:
        PUSH32 "0x000000000000000000000000000000000000000000000000000000000000001E" #   30
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        SGT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SGT OP
      title: "SGT_3"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF57" # -169
        SGT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SGT OP mal
      title: "SGT_4"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        SGT
      success: false
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56"

    assembler: # LT OP
      title: "LT_1"
      code:
        PUSH1 "0x01"
        PUSH1 "0x02"
        LT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # LT OP
      title: "LT_2"
      code:
        PUSH1 "0x01"
        PUSH2 "0x0F00"
        LT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # LT OP
      title: "LT_3"
      code:
        PUSH4 "0x01020304"
        PUSH2 "0x0F00"
        LT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # LT OP mal data
      title: "LT_4"
      code:
        PUSH3 "0x2A3B4C"
        LT
      success: false
      stack: "0x2A3B4C"

    assembler: # SLT OP
      title: "SLT_1"
      code:
        PUSH1 "0x01"
        PUSH1 "0x02"
        SLT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SLT OP
      title: "SLT_2"
      code:
        PUSH32 "0x000000000000000000000000000000000000000000000000000000000000001E" #   30
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        SLT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SLT OP
      title: "SLT_3"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF57" # -169
        SLT
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SLT OP mal
      title: "SLT_4"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        SLT
      success: false
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56"

    assembler: # NOT OP
      title: "NOT_1"
      code:
        PUSH1 "0x01"
        NOT
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"

    assembler: # NOT OP
      title: "NOT_2"
      code:
        PUSH2 "0xA003"
        NOT
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5FFC"

    assembler: # BNOT OP
      title: "BNOT_4"
      code: NOT
      success: false

    assembler: # NOT OP
      title: "NOT_5"
      code:
        PUSH1 "0x00"
        NOT
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
