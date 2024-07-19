# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import macro_assembler, unittest2, eth/common

proc opMiscMain*() =
  suite "Misc Opcodes":
    assembler:
      title:
        "Log0"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push1 "0x20"
        Push1 "0x00"
        Log0
      memory:
        "0x1234"
      logs:
        (
          address: "0x460121576cc7df020759730751f92bd62fd78dd6",
          data: "0x0000000000000000000000000000000000000000000000000000000000001234",
        )

    assembler:
      title:
        "Log1"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push2 "0x9999"
        Push1 "0x20"
        Push1 "0x00"
        Log1
      memory:
        "0x1234"
      logs:
        (
          address: "0x460121576cc7df020759730751f92bd62fd78dd6",
          topics: ["0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234",
        )

    assembler:
      title:
        "Log2"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push2 "0x9999"
        Push2 "0x6666"
        Push1 "0x20"
        Push1 "0x00"
        Log2
      memory:
        "0x1234"
      logs:
        (
          address: "0x460121576cc7df020759730751f92bd62fd78dd6",
          topics: ["0x6666", "0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234",
        )

    assembler:
      title:
        "Log3"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push2 "0x9999"
        Push2 "0x6666"
        Push2 "0x3333"
        Push1 "0x20"
        Push1 "0x00"
        Log3
      memory:
        "0x1234"
      logs:
        (
          address: "0x460121576cc7df020759730751f92bd62fd78dd6",
          topics: ["0x3333", "0x6666", "0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234",
        )

    assembler:
      title:
        "Log4"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push2 "0x9999"
        Push2 "0x6666"
        Push2 "0x3333"
        Push2 "0x5555"
        Push1 "0x20"
        Push1 "0x00"
        Log4
      memory:
        "0x1234"
      logs:
        (
          address: "0x460121576cc7df020759730751f92bd62fd78dd6",
          topics: ["0x5555", "0x3333", "0x6666", "0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234",
        )

    assembler:
      title:
        "Stop_1"
      code:
        Push1 "0x20"
        Push1 "0x30"
        Push1 "0x10"
        Push1 "0x30"
        Push1 "0x11"
        Push1 "0x23"
        Stop
      stack:
        "0x20"
        "0x30"
        "0x10"
        "0x30"
        "0x11"
        "0x23"

    assembler:
      title:
        "Return_1"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push1 "0x20"
        Push1 "0x00"
        Return
      memory:
        "0x1234"
      output:
        "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler:
      title:
        "Return_2"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push1 "0x20"
        Push1 "0x1F"
        Return
      memory:
        "0x1234"
        "0x00"
      output:
        "0x3400000000000000000000000000000000000000000000000000000000000000"

    assembler:
      title:
        "Return_3"
      code:
        Push32 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
        Push1 "0x00"
        Mstore
        Push1 "0x20"
        Push1 "0x00"
        Return
      memory:
        "0xa0b0c0d0e0f0a1b1c1d1e1f1a2b2c2d2e2f2a3b3c3d3e3f3a4b4c4d4e4f4a1b1"
      output:
        "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"

    assembler:
      title:
        "Return_4"
      code:
        Push32 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
        Push1 "0x00"
        Mstore
        Push1 "0x20"
        Push1 "0x10"
        Return
      output:
        "0xE2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B100000000000000000000000000000000"
      memory:
        "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
        "0x00"

#[
  EIP-2315: Simple Subroutines for the EVM
  disabled reason: not included in Berlin hard fork
    assembler:
      title: "Simple routine"
      code:
        Push1 "0x04"
        JUMPSUB
        Stop
        BEGINSUB
        ReturnSUB
      gasUsed: 18
      fork: berlin

    assembler:
      title: "Two levels of subroutines"
      code:
        Push9 "0x00000000000000000C"
        JUMPSUB
        Stop
        BEGINSUB
        Push1 "0x11"
        JUMPSUB
        ReturnSUB
        BEGINSUB
        ReturnSUB
      gasUsed: 36
      fork: berlin

    assembler:
      title: "Failure 1: invalid jump"
      code:
        Push9 "0x01000000000000000C"
        JUMPSUB
        Stop
        BEGINSUB
        Push1 "0x11"
        JUMPSUB
        ReturnSUB
        BEGINSUB
        ReturnSUB
      success: false
      fork: berlin

    assembler:
      title: "Failure 2: shallow return stack"
      code:
        ReturnSUB
        PC
        PC
      success: false
      fork: berlin

    assembler:
      title: "Subroutine at end of code"
      code:
        Push1 "0x05"
        JUMP
        BEGINSUB
        ReturnSUB
        JUMPDEST
        Push1 "0x03"
        JUMPSUB
      gasUsed: 30
      fork: berlin

    assembler:
      title: "Error on 'walk-into-subroutine'"
      code:
        BEGINSUB
        ReturnSUB
        Stop
      success: false
      fork: berlin

    assembler:
      title: "sol test"
      code:
        Push1 "0x02"
        Push1 "0x03"
        Push1 "0x08" # jumpdest
        JUMPSUB
        Stop

        # 0x08
        BEGINSUB
        Push1 "0x0D" # jumpdest
        JUMPSUB
        ReturnSUB

        # 0x0D
        BEGINSUB
        MUL
        ReturnSUB
      gasUsed: 47
      fork: berlin
      stack:
        "0x06"
]#

when isMainModule:
  opMiscMain()
