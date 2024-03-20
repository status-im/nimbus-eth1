# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import macro_assembler, unittest2

proc opBitMain*() =
  suite "Bitwise Opcodes":
    assembler: # And OP
      title: "AND_1"
      code:
        Push1 "0x0A"
        Push1 "0x0A"
        And
      stack: "0x000000000000000000000000000000000000000000000000000000000000000A"

    assembler: # And OP
      title: "AND_2"
      code:
        Push1 "0xC0"
        Push1 "0x0A"
        And
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # And OP mal data
      title: "AND_3"
      code:
        Push1 "0xC0"
        And
      success: false
      stack: "0xC0"

    assembler: # Or OP
      title: "OR_1"
      code:
        Push1 "0xF0"
        Push1 "0x0F"
        Or
      stack: "0x00000000000000000000000000000000000000000000000000000000000000FF"

    assembler: # Or OP
      title: "OR_2"
      code:
        Push1 "0xC3"
        Push1 "0x3C"
        Or
      stack: "0x00000000000000000000000000000000000000000000000000000000000000FF"

    assembler: # Or OP mal data
      title: "OR_3"
      code:
        Push1 "0xC0"
        Or
      success: false
      stack: "0xC0"

    assembler: # Xor OP
      title: "XOR_1"
      code:
        Push1 "0xFF"
        Push1 "0xFF"
        Xor
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Xor OP
      title: "XOR_2"
      code:
        Push1 "0x0F"
        Push1 "0xF0"
        Xor
      stack: "0x00000000000000000000000000000000000000000000000000000000000000FF"

    assembler: # Xor OP mal data
      title: "XOR_3"
      code:
        Push1 "0xC0"
        Xor
      success: false
      stack: "0xC0"

    assembler: # Byte OP
      title: "BYTE_1"
      code:
        Push6 "0xAABBCCDDEEFF"
        Push1 "0x1E"
        Byte
      stack: "0x00000000000000000000000000000000000000000000000000000000000000EE"

    assembler: # Byte OP
      title: "BYTE_2"
      code:
        Push6 "0xAABBCCDDEEFF"
        Push1 "0x20"
        Byte
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Byte OP
      title: "BYTE_3"
      code:
        Push6 "0xAABBCCDDEE3A"
        Push1 "0x1F"
        Byte
      stack: "0x000000000000000000000000000000000000000000000000000000000000003A"

    assembler: # Byte OP mal data
      title: "BYTE_4"
      code:
        Push6 "0xAABBCCDDEE3A"
        Byte
      success: false
      stack: "0xAABBCCDDEE3A"

    assembler: # Shl OP
      title: "SHL_1"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push1 "0x00"
        Shl
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Shl OP
      title: "SHL_2"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push1 "0x01"
        Shl
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000002"

    assembler: # Shl OP
      title: "SHL_3"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push1 "0xff"
        Shl
      fork: Constantinople
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shl OP
      title: "SHL_4"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push2 "0x0100"
        Shl
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shl OP
      title: "SHL_5"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push2 "0x0101"
        Shl
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shl OP
      title: "SHL_6"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0x00"
        Shl
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Shl OP
      title: "SHL_7"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0x01"
        Shl
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"

    assembler: # Shl OP
      title: "SHL_8"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0xff"
        Shl
      fork: Constantinople
      stack: "0x8000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shl OP
      title: "SHL_9"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push2 "0x0100"
        Shl
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shl OP
      title: "SHL_10"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0x01"
        Shl
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shl OP
      title: "SHL_11"
      code:
        Push32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0x01"
        Shl
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"

    assembler: # Shr OP
      title: "SHR_1"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push1 "0x00"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Shr OP
      title: "SHR_2"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push1 "0x01"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shr OP
      title: "SHR_3"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0x01"
        Shr
      fork: Constantinople
      stack: "0x4000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shr OP
      title: "SHR_4"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0xff"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Shr OP
      title: "SHR_5"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push2 "0x0100"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shr OP
      title: "SHR_6"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push2 "0x0101"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shr OP
      title: "SHR_7"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0x00"
        Shr
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Shr OP
      title: "SHR_8"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0x01"
        Shr
      fork: Constantinople
      stack: "0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Shr OP
      title: "SHR_9"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0xff"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Shr OP
      title: "SHR_10"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push2 "0x0100"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Shr OP
      title: "SHR_11"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0x01"
        Shr
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sar OP
      title: "SAR_1"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push1 "0x00"
        Sar
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Sar OP
      title: "SAR_2"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000001"
        Push1 "0x01"
        Sar
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sar OP
      title: "SAR_3"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0x01"
        Sar
      fork: Constantinople
      stack: "0xC000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sar OP
      title: "SAR_4"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0xff"
        Sar
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sar OP
      title: "SAR_5"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push2 "0x0100"
        Sar
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sar OP
      title: "SAR_6"
      code:
        Push32 "0x8000000000000000000000000000000000000000000000000000000000000000"
        Push2 "0x0101"
        Sar
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sar OP
      title: "SAR_7"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0x00"
        Sar
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sar OP
      title: "SAR_8"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0x01"
        Sar
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sar OP
      title: "SAR_9"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0xff"
        Sar
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sar OP
      title: "SAR_10"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push2 "0x0100"
        Sar
      fork: Constantinople
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

    assembler: # Sar OP
      title: "SAR_11"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0x01"
        Sar
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sar OP
      title: "SAR_12"
      code:
        Push32 "0x4000000000000000000000000000000000000000000000000000000000000000"
        Push1 "0xfe"
        Sar
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Sar OP
      title: "SAR_13"
      code:
        Push32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0xf8"
        Sar
      fork: Constantinople
      stack: "0x000000000000000000000000000000000000000000000000000000000000007F"

    assembler: # Sar OP
      title: "SAR_14"
      code:
        Push32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0xfe"
        Sar
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Sar OP
      title: "SAR_15"
      code:
        Push32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push1 "0xff"
        Sar
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sar OP
      title: "SAR_16"
      code:
        Push32 "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        Push2 "0x0100"
        Sar
      fork: Constantinople
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # IsZero OP
      title: "ISZERO_1"
      code:
        Push1 "0x00"
        IsZero
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # IsZero OP
      title: "ISZERO_2"
      code:
        Push1 "0x2A"
        IsZero
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # IsZero OP mal data
      title: "ISZERO_3"
      code: IsZero
      success: false

    assembler: # Eq OP
      title: "EQ_1"
      code:
        Push1 "0x2A"
        Push1 "0x2A"
        Eq
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Eq OP
      title: "EQ_2"
      code:
        Push3 "0x2A3B4C"
        Push3 "0x2A3B4C"
        Eq
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Eq OP
      title: "EQ_3"
      code:
        Push3 "0x2A3B5C"
        Push3 "0x2A3B4C"
        Eq
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Eq OP mal data
      title: "EQ_4"
      code:
        Push3 "0x2A3B4C"
        Eq
      success: false
      stack: "0x2A3B4C"

    assembler: # Gt OP
      title: "GT_1"
      code:
        Push1 "0x01"
        Push1 "0x02"
        Gt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Gt OP
      title: "GT_2"
      code:
        Push1 "0x01"
        Push2 "0x0F00"
        Gt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Gt OP
      title: "GT_3"
      code:
        Push4 "0x01020304"
        Push2 "0x0F00"
        Gt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Gt OP mal data
      title: "GT_4"
      code:
        Push3 "0x2A3B4C"
        Gt
      success: false
      stack: "0x2A3B4C"

    assembler: # Sgt OP
      title: "SGT_1"
      code:
        Push1 "0x01"
        Push1 "0x02"
        Sgt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Sgt OP
      title: "SGT_2"
      code:
        Push32 "0x000000000000000000000000000000000000000000000000000000000000001E" #   30
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Sgt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sgt OP
      title: "SGT_3"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF57" # -169
        Sgt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Sgt OP mal
      title: "SGT_4"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Sgt
      success: false
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56"

    assembler: # Lt OP
      title: "LT_1"
      code:
        Push1 "0x01"
        Push1 "0x02"
        Lt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Lt OP
      title: "LT_2"
      code:
        Push1 "0x01"
        Push2 "0x0F00"
        Lt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Lt OP
      title: "LT_3"
      code:
        Push4 "0x01020304"
        Push2 "0x0F00"
        Lt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Lt OP mal data
      title: "LT_4"
      code:
        Push3 "0x2A3B4C"
        Lt
      success: false
      stack: "0x2A3B4C"

    assembler: # Slt OP
      title: "SLT_1"
      code:
        Push1 "0x01"
        Push1 "0x02"
        Slt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Slt OP
      title: "SLT_2"
      code:
        Push32 "0x000000000000000000000000000000000000000000000000000000000000001E" #   30
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Slt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Slt OP
      title: "SLT_3"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF57" # -169
        Slt
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Slt OP mal
      title: "SLT_4"
      code:
        Push32 "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56" # -170
        Slt
      success: false
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF56"

    assembler: # Not OP
      title: "NOT_1"
      code:
        Push1 "0x01"
        Not
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"

    assembler: # Not OP
      title: "NOT_2"
      code:
        Push2 "0xA003"
        Not
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5FFC"

    assembler: # BNOT OP
      title: "BNOT_4"
      code: Not
      success: false

    assembler: # Not OP
      title: "NOT_5"
      code:
        Push1 "0x00"
        Not
      stack: "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

when isMainModule:
  opBitMain()
