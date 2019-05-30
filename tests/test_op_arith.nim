import macro_assembler, unittest2

proc opArithMain*() =
  suite "Arithmetic Opcodes":
    setup:
      let (blockNumber, chainDB) = initDatabase()

    assembler:
      title: "ADD_1"
      code:
        PUSH1 "0x02"
        PUSH1 "0x02"
        ADD
      stack: "0x04"

    assembler:
      title: "ADD_2"
      code:
        PUSH2 "0x1002"
        PUSH1 "0x02"
        ADD
      stack: "0x1004"

    assembler:
      title: "ADD_3"
      code:
        PUSH2 "0x1002"
        PUSH6 "0x123456789009"
        ADD
      stack: "0x12345678A00B"

    assembler:
      title: "ADD_4"
      code:
        PUSH2 "0x1234"
        ADD
      success: false
      stack: "0x1234"

    assembler:
      title: "ADDMOD_1"
      code:
        PUSH1 "0x02"
        PUSH1 "0x02"
        PUSH1 "0x03"
        ADDMOD
      stack: "0x01"

    assembler:
      title: "ADDMOD_2"
      code:
        PUSH2 "0x1000"
        PUSH1 "0x02"
        PUSH2 "0x1002"
        ADDMOD
        PUSH1 "0x00"
      stack:
        "0x04"
        "0x00"

    assembler:
      title: "ADDMOD_3"
      code:
        PUSH2 "0x1002"
        PUSH6 "0x123456789009"
        PUSH1 "0x02"
        ADDMOD
      stack: "0x093B"

    assembler:
      title: "ADDMOD_4"
      code:
        PUSH2 "0x1234"
        ADDMOD
      stack: "0x1234"
      success: false

    assembler:
      title: "MUL_1"
      code:
        PUSH1 "0x03"
        PUSH1 "0x02"
        MUL
      stack: "0x06"

    assembler:
      title: "MUL_2"
      code:
        PUSH3 "0x222222"
        PUSH1 "0x03"
        MUL
      stack: "0x666666"

    assembler:
      title: "MUL_3"
      code:
        PUSH3 "0x222222"
        PUSH3 "0x333333"
        MUL
      stack: "0x6D3A05F92C6"

    assembler:
      title: "MUL_4"
      code:
        PUSH1 "0x01"
        MUL
      stack: "0x01"
      success: false

    assembler: # MULMOD OP
      title: "MULMOD_2"
      code:
        PUSH3 "0x222222"
        PUSH1 "0x03"
        PUSH1 "0x04"
        MULMOD
      stack: "0x000000000000000000000000000000000000000000000000000000000000000C"

    assembler: # MULMOD OP
      title: "MULMOD_3"
      code:
        PUSH3 "0x222222"
        PUSH3 "0x333333"
        PUSH3 "0x444444"
        MULMOD
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # MULMOD OP mal
      title: "MULMOD_4"
      code:
        PUSH1 "0x01"
        MULMOD
      success: false
      stack: "0x01"

    assembler: # DIV OP
      title: "DIV_1"
      code:
        PUSH1 "0x02"
        PUSH1 "0x04"
        DIV
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # DIV OP
      title: "DIV_2"
      code:
        PUSH1 "0x33"
        PUSH1 "0x99"
        DIV
      stack: "0x0000000000000000000000000000000000000000000000000000000000000003"

    assembler: # DIV OP
      title: "DIV_3"
      code:
        PUSH1 "0x22"
        PUSH1 "0x99"
        DIV
      stack: "0x0000000000000000000000000000000000000000000000000000000000000004"

    assembler: # DIV OP
      title: "DIV_4"
      code:
        PUSH1 "0x15"
        PUSH1 "0x99"
        DIV
      stack: "0x0000000000000000000000000000000000000000000000000000000000000007"

    assembler: # DIV OP
      title: "DIV_5"
      code:
        PUSH1 "0x04"
        PUSH1 "0x07"
        DIV
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # DIV OP
      title: "DIV_6"
      code:
        PUSH1 "0x07"
        DIV
      success: false
      stack: "0x07"

    assembler: # SDIV OP
      title: "SDIV_1"
      code:
        PUSH2 "0x03E8"
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC18"
        SDIV
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # SDIV OP
      title: "SDIV_2"
      code:
        PUSH1 "0xFF"
        PUSH1 "0xFF"
        SDIV
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SDIV OP, SDIV by zero should be zero
      title: "SDIV_3"
      code:
        PUSH1 "0x00"
        PUSH1 "0xFF"
        SDIV
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SDIV OP mal
      title: "SDIV_4"
      code:
        PUSH1 "0xFF"
        SDIV
      success: false
      stack: "0xFF"

    assembler: # -2^255 SDIV -1 = -2^255 (special case in yellow paper)
      title: "SDIV_5"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" # -1
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000" # -2^255 == low(int256)
        SDIV
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"   # -2^255 == low(int256)

    assembler: # -2^255 SDIV 1 = -2^255
      title: "SDIV_6"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000001" # 1
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000" # -2^255 == low(int256)
        SDIV
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"   # -2^255 == low(int256)

    assembler: # -2 SDIV 2 = -1
      title: "SDIV_7"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000002" #  2
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE" # -2
        SDIV
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"   # -1

    assembler: # 4 SDIV -2 = -2
      title: "SDIV_8"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE" # -2
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000004" #  4
        SDIV
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"   # -2

    assembler: # -4 SDIV 2 = -2
      title: "SDIV_9"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000002" # -4
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC" #  2
        SDIV
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"   # -2

    assembler: # -1 SDIV 2 = 0
      title: "SDIV_10"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000002" #  2
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" # -1
        SDIV
      stack: "0x00"                                                                 #  0

    assembler: # low(int256) SDIV low(int256) = 1
      title: "SDIV_11"
      code:
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        SDIV
      stack: "0x01"                                                                 # 1

    assembler: # low(int256) SDIV 2
      title: "SDIV_12"
      code:
        PUSH32 "0x0000000000000000000000000000000000000000000000000000000000000002" # 2
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        SDIV
      stack:   "0xC000000000000000000000000000000000000000000000000000000000000000" # negative half low(int256)

    assembler: # low(int256) SDIV -2
      title: "SDIV_13"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE" # -2
        PUSH32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        SDIV
      stack:   "0x4000000000000000000000000000000000000000000000000000000000000000" # positive version of SDIV_12

    assembler:
      title: "SDIV_14"
      code:
        PUSH1  "0x01"  # 1
        PUSH1  "0x7F"  # 127
        SHL            # 1 shl 127 (move the bit to the center or 128th position)

        PUSH1  "0x01"  # 1
        PUSH1  "0xFF"  # 255
        SHL            # 1 shl 255 (create low(int256))

        SDIV
      stack:   "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000" # half of the hi bits are set
      fork: constantinople

    assembler: # SUB OP
      title: "SUB_1"
      code:
        PUSH1 "0x04"
        PUSH1 "0x06"
        SUB
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # SUB OP
      title: "SUB_2"
      code:
        PUSH2 "0x4444"
        PUSH2 "0x6666"
        SUB
      stack: "0x0000000000000000000000000000000000000000000000000000000000002222"

    assembler: # SUB OP
      title: "SUB_3"
      code:
        PUSH2 "0x4444"
        PUSH4 "0x99996666"
        SUB
      stack: "0x0000000000000000000000000000000000000000000000000000000099992222"

    assembler: # SUB OP mal
      title: "SUB_4"
      code:
        PUSH4 "0x99996666"
        SUB
      success: false
      stack: "0x99996666"

    assembler: # EXP OP
      title: "EXP_1"
      code:
        PUSH1 "0x03"
        PUSH1 "0x02"
        EXP
      stack: "0x0000000000000000000000000000000000000000000000000000000000000008"
      #assertEquals(4, gas);

    assembler: # EXP OP
      title: "EXP_2"
      code:
        PUSH1 "0x00"
        PUSH3 "0x123456"
        EXP
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"
      #assertEquals(3, gas);

    assembler: # EXP OP
      title: "EXP_3"
      code:
        PUSH2 "0x1122"
        PUSH1 "0x01"
        EXP
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"
      #assertEquals(5, gas);

    assembler: # EXP OP mal
      title: "EXP_4"
      code:
        PUSH3 "0x123456"
        EXP
      success: false
      stack: "0x123456"

    assembler: # MOD OP
      title: "MOD_1"
      code:
        PUSH1 "0x03"
        PUSH1 "0x04"
        MOD
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # MOD OP
      title: "MOD_2"
      code:
        PUSH2 "0x012C"
        PUSH2 "0x01F4"
        MOD
      stack: "0x00000000000000000000000000000000000000000000000000000000000000C8"

    assembler: # MOD OP
      title: "MOD_3"
      code:
        PUSH1 "0x04"
        PUSH1 "0x02"
        MOD
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # MOD OP mal
      title: "MOD_4"
      code:
        PUSH1 "0x04"
        MOD
      success: false
      stack: "0x04"

    assembler: # SMOD OP
      title: "SMOD_1"
      code:
        PUSH1 "0x03"
        PUSH1 "0x04"
        SMOD
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # SMOD OP
      title: "SMOD_2"
      code:
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE2" # -30
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        SMOD
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEC"

    assembler: # SMOD OP
      title: "SMOD_3"
      code:
        PUSH32 "0x000000000000000000000000000000000000000000000000000000000000001E" # 30
        PUSH32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        SMOD
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEC"

    assembler: # SMOD OP mal
      title: "SMOD_4"
      code:
        PUSH32 "0x000000000000000000000000000000000000000000000000000000000000001E" # 30
        SMOD
      success: false
      stack: "0x000000000000000000000000000000000000000000000000000000000000001E"

    # real case, EVM bug, integer over flow
    assembler: # SIGNEXTEND OP
      title: "SIGNEXTEND_1"
      code:
        PUSH32 "0x000000000000000000000000000000003f9b347132d29b62d161117bca8c7307"
        PUSH1 "0x0F"
        SIGNEXTEND
      stack: "0x000000000000000000000000000000003f9b347132d29b62d161117bca8c7307"
