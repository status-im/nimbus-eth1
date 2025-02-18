# Nimbus
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import macro_assembler, unittest2

proc opArithMain*() =
  suite "Arithmetic Opcodes":
    assembler:
      title: "Add_1"
      code:
        Push1 "0x02"
        Push1 "0x02"
        Add
      stack: "0x04"

    assembler:
      title: "Add_2"
      code:
        Push2 "0x1002"
        Push1 "0x02"
        Add
      stack: "0x1004"

    assembler:
      title: "Add_3"
      code:
        Push2 "0x1002"
        Push6 "0x123456789009"
        Add
      stack: "0x12345678A00B"

    assembler:
      title: "Add_4"
      code:
        Push2 "0x1234"
        Add
      success: false
      stack: "0x1234"

    assembler:
      title: "Addmod_1"
      code:
        Push1 "0x02"
        Push1 "0x02"
        Push1 "0x03"
        Addmod
      stack: "0x01"

    assembler:
      title: "Addmod_2"
      code:
        Push2 "0x1000"
        Push1 "0x02"
        Push2 "0x1002"
        Addmod
        Push1 "0x00"
      stack:
        "0x04"
        "0x00"

    assembler:
      title: "Addmod_3"
      code:
        Push2 "0x1002"
        Push6 "0x123456789009"
        Push1 "0x02"
        Addmod
      stack: "0x093B"

    assembler:
      title: "Addmod_4"
      code:
        Push2 "0x1234"
        Addmod
      stack: "0x1234"
      success: false

    assembler:
      title: "MUL_1"
      code:
        Push1 "0x03"
        Push1 "0x02"
        Mul
      stack: "0x06"

    assembler:
      title: "MUL_2"
      code:
        Push3 "0x222222"
        Push1 "0x03"
        Mul
      stack: "0x666666"

    assembler:
      title: "MUL_3"
      code:
        Push3 "0x222222"
        Push3 "0x333333"
        Mul
      stack: "0x6D3A05F92C6"

    assembler:
      title: "MUL_4"
      code:
        Push1 "0x01"
        Mul
      stack: "0x01"
      success: false

    assembler: # Mulmod OP
      title: "MULMOD_2"
      code:
        Push3 "0x222222"
        Push1 "0x03"
        Push1 "0x04"
        Mulmod
      stack: "0x000000000000000000000000000000000000000000000000000000000000000C"

    assembler: # Mulmod OP
      title: "MULMOD_3"
      code:
        Push3 "0x222222"
        Push3 "0x333333"
        Push3 "0x444444"
        Mulmod
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Mulmod OP mal
      title: "MULMOD_4"
      code:
        Push1 "0x01"
        Mulmod
      success: false
      stack: "0x01"

    assembler: # Div OP
      title: "DIV_1"
      code:
        Push1 "0x02"
        Push1 "0x04"
        Div
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # Div OP
      title: "DIV_2"
      code:
        Push1 "0x33"
        Push1 "0x99"
        Div
      stack: "0x0000000000000000000000000000000000000000000000000000000000000003"

    assembler: # Div OP
      title: "DIV_3"
      code:
        Push1 "0x22"
        Push1 "0x99"
        Div
      stack: "0x0000000000000000000000000000000000000000000000000000000000000004"

    assembler: # Div OP
      title: "DIV_4"
      code:
        Push1 "0x15"
        Push1 "0x99"
        Div
      stack: "0x0000000000000000000000000000000000000000000000000000000000000007"

    assembler: # Div OP
      title: "DIV_5"
      code:
        Push1 "0x04"
        Push1 "0x07"
        Div
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Div OP
      title: "DIV_6"
      code:
        Push1 "0x07"
        Div
      success: false
      stack: "0x07"

    assembler: # Sdiv OP
      title: "SDIV_1"
      code:
        Push2 "0x03E8"
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC18"
        Sdiv
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sdiv OP
      title: "SDIV_2"
      code:
        Push1 "0xFF"
        Push1 "0xFF"
        Sdiv
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Sdiv OP, Sdiv by zero should be zero
      title: "SDIV_3"
      code:
        Push1 "0x00"
        Push1 "0xFF"
        Sdiv
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sdiv OP mal
      title: "SDIV_4"
      code:
        Push1 "0xFF"
        Sdiv
      success: false
      stack: "0xFF"

    assembler: # -2^255 Sdiv -1 = -2^255 (special case in yellow paper)
      title: "SDIV_5"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" # -1
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000" # -2^255 == low(int256)
        Sdiv
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"   # -2^255 == low(int256)

    assembler: # -2^255 Sdiv 1 = -2^255
      title: "SDIV_6"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001" # 1
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000" # -2^255 == low(int256)
        Sdiv
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"   # -2^255 == low(int256)

    assembler: # -2 Sdiv 2 = -1
      title: "SDIV_7"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000002" #  2
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE" # -2
        Sdiv
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"   # -1

    assembler: # 4 Sdiv -2 = -2
      title: "SDIV_8"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE" # -2
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000004" #  4
        Sdiv
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"   # -2

    assembler: # -4 Sdiv 2 = -2
      title: "SDIV_9"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000002" # -4
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC" #  2
        Sdiv
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"   # -2

    assembler: # -1 Sdiv 2 = 0
      title: "SDIV_10"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000002" #  2
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" # -1
        Sdiv
      stack: "0x00"                                                                 #  0

    assembler: # low(int256) Sdiv low(int256) = 1
      title: "SDIV_11"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        Sdiv
      stack: "0x01"                                                                 # 1

    assembler: # low(int256) Sdiv 2
      title: "SDIV_12"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000002" # 2
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        Sdiv
      stack:   "0xC000000000000000000000000000000000000000000000000000000000000000" # negative half low(int256)

    assembler: # low(int256) Sdiv -2
      title: "SDIV_13"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE" # -2
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000" # low(int256)
        Sdiv
      stack:   "0x4000000000000000000000000000000000000000000000000000000000000000" # positive version of SDIV_12

    assembler:
      title: "SDIV_14"
      code:
        Push1  "0x01"  # 1
        Push1  "0x7F"  # 127
        Shl            # 1 shl 127 (move the bit to the center or 128th position)

        Push1  "0x01"  # 1
        Push1  "0xFF"  # 255
        Shl            # 1 shl 255 (create low(int256))

        Sdiv
      stack:   "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000" # half of the hi bits are set
      fork: Constantinople

    assembler: # Sub OP
      title: "SUB_1"
      code:
        Push1 "0x04"
        Push1 "0x06"
        Sub
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # Sub OP
      title: "SUB_2"
      code:
        Push2 "0x4444"
        Push2 "0x6666"
        Sub
      stack: "0x0000000000000000000000000000000000000000000000000000000000002222"

    assembler: # Sub OP
      title: "SUB_3"
      code:
        Push2 "0x4444"
        Push4 "0x99996666"
        Sub
      stack: "0x0000000000000000000000000000000000000000000000000000000099992222"

    assembler: # Sub OP mal
      title: "SUB_4"
      code:
        Push4 "0x99996666"
        Sub
      success: false
      stack: "0x99996666"

    assembler: # Exp OP
      title: "EXP_1"
      code:
        Push1 "0x03"
        Push1 "0x02"
        Exp
      stack: "0x0000000000000000000000000000000000000000000000000000000000000008"
      #assertEquals(4, gas);

    assembler: # Exp OP
      title: "EXP_2"
      code:
        Push1 "0x00"
        Push3 "0x123456"
        Exp
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"
      #assertEquals(3, gas);

    assembler: # Exp OP
      title: "EXP_3"
      code:
        Push2 "0x1122"
        Push1 "0x01"
        Exp
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"
      #assertEquals(5, gas);

    assembler: # Exp OP mal
      title: "EXP_4"
      code:
        Push3 "0x123456"
        Exp
      success: false
      stack: "0x123456"

    assembler: # Mod OP
      title: "MOD_1"
      code:
        Push1 "0x03"
        Push1 "0x04"
        Mod
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Mod OP
      title: "MOD_2"
      code:
        Push2 "0x012C"
        Push2 "0x01F4"
        Mod
      stack: "0x00000000000000000000000000000000000000000000000000000000000000C8"

    assembler: # Mod OP
      title: "MOD_3"
      code:
        Push1 "0x04"
        Push1 "0x02"
        Mod
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # Mod OP mal
      title: "MOD_4"
      code:
        Push1 "0x04"
        Mod
      success: false
      stack: "0x04"

    assembler: # Smod OP
      title: "SMOD_1"
      code:
        Push1 "0x03"
        Push1 "0x04"
        Smod
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Smod OP
      title: "SMOD_2"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE2" # -30
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Smod
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEC"

    assembler: # Smod OP
      title: "SMOD_3"
      code:
        Push32 "0x000000000000000000000000000000000000000000000000000000000000001E" # 30
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Smod
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEC"

    assembler: # Smod OP mal
      title: "SMOD_4"
      code:
        Push32 "0x000000000000000000000000000000000000000000000000000000000000001E" # 30
        Smod
      success: false
      stack: "0x000000000000000000000000000000000000000000000000000000000000001E"

    # real case, EVM bug, integer over flow
    assembler: # SignExtend OP
      title: "SIGNEXTEND_1"
      code:
        Push32 "0x000000000000000000000000000000003f9b347132d29b62d161117bca8c7307"
        Push1 "0x0F"
        SignExtend
      stack: "0x000000000000000000000000000000003f9b347132d29b62d161117bca8c7307"

    assembler:
      title: "Byte with overflow pos 1"
      code:
        Push32 "0x77676767676760000000000000001002e000000000000040000000e000000000"
        Push32 "0x0000000000000000000000000000000000000000000000010000000000000000"
        Byte
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler:
      title: "Byte with overflow pos 2"
      code:
        Push32 "0x001f000000000000000000000000000000200000000100000000000000000000"
        Push32 "0x0000000000000000000000000000000080000000000000000000000000000001"
        Byte
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

opArithMain()
