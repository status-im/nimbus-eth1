# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[macros, strutils],
  unittest2,
  ./macro_assembler

proc opMemoryMain*() =
  suite "Memory Opcodes":
    assembler: # Push1 OP
      title: "Push1"
      code:
        Push1 "0xa0"
      stack: "0x00000000000000000000000000000000000000000000000000000000000000A0"

    assembler: # Push2 OP
      title: "Push2"
      code:
        Push2 "0xa0b0"
      stack: "0x000000000000000000000000000000000000000000000000000000000000A0B0"

    assembler: # Push3 OP
      title: "Push3"
      code:
        Push3 "0xA0B0C0"
      stack: "0x0000000000000000000000000000000000000000000000000000000000A0B0C0"

    assembler: # Push4 OP
      title: "Push4"
      code:
        Push4 "0xA0B0C0D0"
      stack: "0x00000000000000000000000000000000000000000000000000000000A0B0C0D0"

    assembler: # Push5 OP
      title: "Push5"
      code:
        Push5 "0xA0B0C0D0E0"
      stack: "0x000000000000000000000000000000000000000000000000000000A0B0C0D0E0"

    assembler: # Push6 OP
      title: "Push6"
      code:
        Push6 "0xA0B0C0D0E0F0"
      stack: "0x0000000000000000000000000000000000000000000000000000A0B0C0D0E0F0"

    assembler: # Push7 OP
      title: "Push7"
      code:
        Push7 "0xA0B0C0D0E0F0A1"
      stack: "0x00000000000000000000000000000000000000000000000000A0B0C0D0E0F0A1"

    assembler: # Push8 OP
      title: "Push8"
      code:
        Push8 "0xA0B0C0D0E0F0A1B1"
      stack: "0x000000000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1"

    assembler: # Push9 OP
      title: "Push9"
      code:
        Push9 "0xA0B0C0D0E0F0A1B1C1"
      stack: "0x0000000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1"

    assembler: # Push10 OP
      title: "Push10"
      code:
        Push10 "0xA0B0C0D0E0F0A1B1C1D1"
      stack: "0x00000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1"

    assembler: # Push11 OP
      title: "Push11"
      code:
        Push11 "0xA0B0C0D0E0F0A1B1C1D1E1"
      stack: "0x000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1"

    assembler: # Push12 OP
      title: "Push12"
      code:
        Push12 "0xA0B0C0D0E0F0A1B1C1D1E1F1"
      stack: "0x0000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1"

    assembler: # Push13 OP
      title: "Push13"
      code:
        Push13 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2"
      stack: "0x00000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2"

    assembler: # Push14 OP
      title: "Push14"
      code:
        Push14 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2"
      stack: "0x000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2"

    assembler: # Push15 OP
      title: "Push15"
      code:
        Push15 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2"
      stack: "0x0000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2"

    assembler: # Push16 OP
      title: "Push16"
      code:
        Push16 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2"
      stack: "0x00000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2"

    assembler: # Push17 OP
      title: "Push17"
      code:
        Push17 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2"
      stack: "0x000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2"

    assembler: # Push18 OP
      title: "Push18"
      code:
        Push18 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2"
      stack: "0x0000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2"

    assembler: # Push19 OP
      title: "Push19"
      code:
        Push19 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3"
      stack: "0x00000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3"

    assembler: # Push20 OP
      title: "Push20"
      code:
        Push20 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3"
      stack: "0x000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3"

    assembler: # Push21 OP
      title: "Push21"
      code:
        Push21 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3"
      stack: "0x0000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3"

    assembler: # Push22 OP
      title: "Push22"
      code:
        Push22 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3"
      stack: "0x00000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3"

    assembler: # Push23 OP
      title: "Push23"
      code:
        Push23 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3"
      stack: "0x000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3"

    assembler: # Push24 OP
      title: "Push24"
      code:
        Push24 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3"
      stack: "0x0000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3"

    assembler: # Push25 OP
      title: "Push25"
      code:
        Push25 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4"
      stack: "0x00000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4"

    assembler: # Push26 OP
      title: "Push26"
      code:
        Push26 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4"
      stack: "0x000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4"

    assembler: # Push27 OP
      title: "Push27"
      code:
        Push27 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4"
      stack: "0x0000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4"

    assembler: # Push28 OP
      title: "Push28"
      code:
        Push28 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4"
      stack: "0x00000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4"

    assembler: # Push29 OP
      title: "Push29"
      code:
        Push29 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4"
      stack: "0x000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4"

    assembler: # Push30 OP
      title: "Push30"
      code:
        Push30 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4"
      stack: "0x0000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4"

    assembler: # Push31 OP
      title: "Push31"
      code:
        Push31 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1"
      stack: "0x00A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1"

    assembler: # Push32 OP
      title: "Push32"
      code:
        Push32 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
      stack: "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"

    # macro assembler prevented this
    #assembler: # PushN OP not enough data
    #  title: "PushN_1"
    #  code:
    #    Push2 "0xAA"
    #  stack: "0x000000000000000000000000000000000000000000000000000000000000AA00"
    #  success: false
    #
    #assembler: # PushN OP not enough data
    #  title: "PushN_2"
    #  code:
    #    Push32 "0xAABB"
    #  stack: "0xAABB000000000000000000000000000000000000000000000000000000000000"
    #  success: false

    assembler: # Pop OP
      title: "Pop_1"
      code:
        Push2 "0x0000"
        Push1 "0x01"
        Push3 "0x000002"
        Pop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # Pop OP
      title: "Pop_2"
      code:
        Push2 "0x0000"
        Push1 "0x01"
        Push3 "0x000002"
        Pop
        Pop
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler:# Pop OP mal data
      title: "Pop_3"
      code:
        Push2 "0x0000"
        Push1 "0x01"
        Push3 "0x000002"
        Pop
        Pop
        Pop
        Pop
      success: false

    macro generateDUPS(): untyped =
      result = newStmtList()

      for i in 1 .. 16:
        let title = newStmtList(newLit("DUP_" & $i))
        let pushIdent = ident("Push1")
        var body = newStmtList()
        var stack = newStmtList()

        for x in 0 ..< i:
          let val = newLit("0x" & toHex(x+10, 2))
          body.add quote do:
            `pushIdent` `val`
          stack.add quote do:
            `val`

        let stackVal = newLit("0x" & toHex(10, 2))
        stack.add quote do:
          `stackVal`

        let dupIdent = ident("DUP" & $i)
        body.add quote do:
          `dupIdent`

        let titleCall = newCall(ident("title"), title)
        let codeCall = newCall(ident("code"), body)
        let stackCall = newCall(ident("stack"), stack)

        result.add quote do:
          assembler:
            `titleCall`
            `codeCall`
            `stackCall`

    generateDUPS()

    assembler: # DUPN OP mal data
      title: "DUPN_2"
      code:
        Dup1
      success: false

    macro generateSWAPS(): untyped =
      result = newStmtList()

      for i in 1 .. 16:
        let title = newStmtList(newLit("SWAP_" & $i))
        let pushIdent = ident("Push1")
        var body = newStmtList()
        var stack = newStmtList()

        for x in countdown(i, 0):
          let val = newLit("0x" & toHex(x+10, 2))
          body.add quote do:
            `pushIdent` `val`
          if x == i:
            let val = newLit("0x" & toHex(0+10, 2))
            stack.add quote do:
              `val`
          elif x == 0:
            let val = newLit("0x" & toHex(i+10, 2))
            stack.add quote do:
              `val`
          else:
            stack.add quote do:
              `val`

        let swapIdent = ident("SWAP" & $i)
        body.add quote do:
          `swapIdent`

        let titleCall = newCall(ident("title"), title)
        let codeCall = newCall(ident("code"), body)
        let stackCall = newCall(ident("stack"), stack)

        result.add quote do:
          assembler:
            `titleCall`
            `codeCall`
            `stackCall`

    generateSWAPS()

    assembler:# SWAPN OP mal data
      title: "SWAPN_2"
      code:
        Swap1
      success: false

    assembler: # Mstore OP
      title: "Mstore_1"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
      memory: "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler: # Mstore OP
      title: "Mstore_2"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push2 "0x5566"
        Push1 "0x20"
        Mstore
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000001234"
        "0x0000000000000000000000000000000000000000000000000000000000005566"

    assembler: # Mstore OP
      title: "Mstore_3"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Mstore
        Push2 "0x5566"
        Push1 "0x20"
        Mstore
        Push2 "0x8888"
        Push1 "0x00"
        Mstore
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000008888"
        "0x0000000000000000000000000000000000000000000000000000000000005566"

    assembler: # Mstore OP
      title: "Mstore_4"
      code:
        Push2 "0x1234"
        Push1 "0xA0"
        Mstore
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler: # Mstore OP
      title: "Mstore_5"
      code:
        Push2 "0x1234"
        Mstore
      success: false
      stack: "0x1234"

    assembler: # Mload OP
      title: "Mload_1"
      code:
        Push1 "0x00"
        Mload
      memory: "0x0000000000000000000000000000000000000000000000000000000000000000"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Mload OP
      title: "Mload_2"
      code:
        Push1 "0x22"
        Mload
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Mload OP
      title: "Mload_3"
      code:
        Push1 "0x20"
        Mload
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Mload OP
      title: "Mload_4"
      code:
        Push2 "0x1234"
        Push1 "0x20"
        Mstore
        Push1 "0x20"
        Mload
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000001234"
      stack: "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler: # Mload OP
      title: "Mload_5"
      code:
        Push2 "0x1234"
        Push1 "0x20"
        Mstore
        Push1 "0x1F"
        Mload
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000001234"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000012"

    assembler: # Mload OP mal data
      title: "Mload_6"
      code:
        Mload
      success: false

    assembler: # Mstore8 OP
      title: "Mstore8_1"
      code:
        Push1 "0x11"
        Push1 "0x00"
        Mstore8
      memory: "0x1100000000000000000000000000000000000000000000000000000000000000"

    assembler: # Mstore8 OP
      title: "Mstore8_2"
      code:
        Push1 "0x22"
        Push1 "0x01"
        Mstore8
      memory: "0x0022000000000000000000000000000000000000000000000000000000000000"

    assembler: # Mstore8 OP
      title: "Mstore8_3"
      code:
        Push1 "0x22"
        Push1 "0x21"
        Mstore8
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0022000000000000000000000000000000000000000000000000000000000000"

    assembler: # Mstore8 OP mal
      title: "Mstore8_4"
      code:
        Push1 "0x22"
        Mstore8
      success: false
      stack: "0x22"

    assembler: # Sstore OP
      title: "Sstore_1"
      code:
        Push1 "0x22"
        Push1 "0xAA"
        Sstore
      storage:
        "0xAA": "0x22"

    assembler: # Sstore OP
      title: "Sstore_2"
      code:
        Push1 "0x22"
        Push1 "0xAA"
        Sstore
        Push1 "0x22"
        Push1 "0xBB"
        Sstore
      storage:
        "0xAA": "0x22"
        "0xBB": "0x22"

    assembler: # Sstore OP
      title: "Sstore_3"
      code:
        Push1 "0x22"
        Sstore
      success: false
      stack: "0x22"

    assembler: # Sstore EIP1283
      title: "Sstore_NET_1"
      code: "60006000556000600055"
      fork: Constantinople
      gasUsed: 412

    assembler: # Sstore EIP1283
      title: "Sstore_NET_2"
      code: "60006000556001600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_3"
      code: "60016000556000600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_4"
      code: "60016000556002600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_5"
      code: "60016000556001600055"
      fork: Constantinople
      gasUsed: 20212

    # Sets Storage row on "cow" address:
    # 0: 1
    # private void setStorageToOne(VM vm) {
    #       # Sets storage value to 1 and commits
    #           code: "60006000556001600055"
    #           fork: Constantinople
    #       invoke.getRepository().commit()
    #       invoke.setOrigRepository(invoke.getRepository())

    assembler: # Sstore EIP1283
      title: "Sstore_NET_6"
      code: "60006000556000600055"
      fork: Constantinople
      gasUsed: 412

    assembler: # Sstore EIP1283
      title: "Sstore_NET_7"
      code: "60006000556001600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_8"
      code: "60006000556002600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_9"
      code: "60026000556000600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_10"
      code: "60026000556003600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_11"
      code: "60026000556001600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_12"
      code: "60026000556002600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_13"
      code: "60016000556000600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_14"
      code: "60016000556002600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_15"
      code: "60016000556001600055"
      fork: Constantinople
      gasUsed: 20212

    assembler: # Sstore EIP1283
      title: "Sstore_NET_16"
      code: "600160005560006000556001600055"
      fork: Constantinople
      gasUsed: 40218

    assembler: # Sstore EIP1283
      title: "Sstore_NET_17"
      code: "600060005560016000556000600055"
      fork: Constantinople
      gasUsed: 20418

    assembler: # Sload OP
      title: "Sload_1"
      code:
        Push1 "0xAA"
        Sload
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Sload OP
      title: "Sload_2"
      code:
        Push1 "0x22"
        Push1 "0xAA"
        Sstore
        Push1 "0xAA"
        Sload
      stack: "0x0000000000000000000000000000000000000000000000000000000000000022"

    assembler: # Sload OP
      title: "Sload_3"
      code:
        Push1 "0x22"
        Push1 "0xAA"
        Sstore
        Push1 "0x33"
        Push1 "0xCC"
        Sstore
        Push1 "0xCC"
        Sload
      stack: "0x0000000000000000000000000000000000000000000000000000000000000033"

    assembler: # Sload OP
      title: "Sload_4"
      code: Sload
      success: false

    assembler: # Pc OP
      title: "Pc_1"
      code: Pc
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Pc OP
      title: "Pc_2"
      code:
        Push1 "0x22"
        Push1 "0xAA"
        Mstore
        Push1 "0xAA"
        Sload
        Pc
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000008"
      memory:
        "0x00"
        "0x00"
        "0x00"
        "0x00"
        "0x00"
        "0x00"
        "0x0000000000000000002200000000000000000000000000000000000000000000"

    assembler: # Jump OP mal data
      title: "Jump_1"
      code:
        Push1 "0xAA"
        Push1 "0xBB"
        Push1 "0x0E"
        Jump
        Push1 "0xCC"
        Push1 "0xDD"
        Push1 "0xEE"
        JumpDest
        Push1 "0xFF"
      stack:
        "0xaa"
        "0x00000000000000000000000000000000000000000000000000000000000000bb"
      success: false

    assembler: # Jump OP mal data
      title: "Jump_2"
      code:
        Push1 "0x0C"
        Push1 "0x0C"
        Swap1
        Jump
        Push1 "0xCC"
        Push1 "0xDD"
        Push1 "0xEE"
        Push1 "0xFF"
      success: false
      stack : "0x0C"

    assembler: # JumpI OP
      title: "JumpI_1"
      code:
        Push1 "0x01"
        Push1 "0x05"
        JumpI
        JumpDest
        Push1 "0xCC"
      stack: "0x00000000000000000000000000000000000000000000000000000000000000CC"

    assembler: # JumpI OP
      title: "JumpI_2"
      code:
        Push4 "0x00000000"
        Push1 "0x44"
        JumpI
        Push1 "0xCC"
        Push1 "0xDD"
      stack:
        "0x00000000000000000000000000000000000000000000000000000000000000CC"
        "0x00000000000000000000000000000000000000000000000000000000000000DD"

    assembler: # JumpI OP mal
      title: "JumpI_3"
      code:
        Push1 "0x01"
        JumpI
      success: false
      stack: "0x01"

    assembler: # JumpI OP mal
      title: "JumpI_4"
      code:
        Push1 "0x01"
        Push1 "0x22"
        Swap1
        Swap1
        JumpI
      success: false

    assembler: # Jump OP mal data
      title: "JumpDest_1"
      code:
        Push1 "0x23"
        Push1 "0x08"
        Jump
        Push1 "0x01"
        JumpDest
        Push1 "0x02"
        Sstore
      storage:
        "0x02": "0x00"
      stack: "0x23"
      success: false

    # success or not?
    assembler: # JumpDest OP for JumpI
      title: "JumpDest_2"
      code:
        Push1 "0x23"
        Push1 "0x01"
        Push1 "0x09"
        JumpI
        Push1 "0x01"
        JumpDest
        Push1 "0x02"
        Sstore
      #success: false
      storage:
        "0x02": "0x23"

    assembler: # Msize OP
      title: "Msize_1"
      code:
        Msize
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # Msize OP
      title: "Msize_2"
      code:
        Push1 "0x20"
        Push1 "0x30"
        Mstore
        Msize
      stack:
        "0x60"
      memory:
        "0x00"
        "0x00"
        "0x0000000000000000000000000000002000000000000000000000000000000000"

    assembler:
      title: "Mcopy 1"
      code:
        Push32 "0x0000000000000000000000000000000000000000000000000000000000000000"
        Push1  "0x00"
        Mstore
        Push32 "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        Push1  "0x20"
        Mstore
        Push1  "0x20" # len
        Push1  "0x20" # src
        Push1  "0x00" # dst
        Mcopy
      memory:
        "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
      fork: Cancun

    assembler:
      title: "Mcopy 2: Overlap"
      code:
        Push32 "0x0101010101010101010101010101010101010101010101010101010101010101"
        Push1  "0x00"
        Mstore
        Push1  "0x20" # len
        Push1  "0x00" # src
        Push1  "0x00" # dst
        Mcopy
      memory:
        "0x0101010101010101010101010101010101010101010101010101010101010101"
      fork: Cancun

    assembler:
      title: "Mcopy 3"
      code:
        Push1 "0x00"
        Push1 "0x00"
        Mstore8
        Push1 "0x01"
        Push1 "0x01"
        Mstore8
        Push1 "0x02"
        Push1 "0x02"
        Mstore8
        Push1 "0x03"
        Push1 "0x03"
        Mstore8
        Push1 "0x04"
        Push1 "0x04"
        Mstore8
        Push1 "0x05"
        Push1 "0x05"
        Mstore8
        Push1 "0x06"
        Push1 "0x06"
        Mstore8
        Push1 "0x07"
        Push1 "0x07"
        Mstore8
        Push1 "0x08"
        Push1 "0x08"
        Mstore8
        Push1  "0x08" # len
        Push1  "0x01" # src
        Push1  "0x00" # dst
        Mcopy
      memory:
        "0x0102030405060708080000000000000000000000000000000000000000000000"
      fork: Cancun

    assembler:
      title: "Mcopy 4"
      code:
        Push1 "0x00"
        Push1 "0x00"
        Mstore8
        Push1 "0x01"
        Push1 "0x01"
        Mstore8
        Push1 "0x02"
        Push1 "0x02"
        Mstore8
        Push1 "0x03"
        Push1 "0x03"
        Mstore8
        Push1 "0x04"
        Push1 "0x04"
        Mstore8
        Push1 "0x05"
        Push1 "0x05"
        Mstore8
        Push1 "0x06"
        Push1 "0x06"
        Mstore8
        Push1 "0x07"
        Push1 "0x07"
        Mstore8
        Push1 "0x08"
        Push1 "0x08"
        Mstore8
        Push1  "0x08" # len
        Push1  "0x00" # src
        Push1  "0x01" # dst
        Mcopy
      memory:
        "0x0000010203040506070000000000000000000000000000000000000000000000"
      fork: Cancun

    assembler:
      title: "Tstore/Tload"
      code:
        Push1 "0xAA"
        Push1 "0xBB"
        Tstore
        Push1 "0xBB"
        Tload
      stack:
        "0x00000000000000000000000000000000000000000000000000000000000000AA"
      fork: Cancun

    assembler:
      title: "Tload stack underflow not crash"
      code:
        Push1 "0xAA"
        Push1 "0xBB"
        Tstore
        Tload
      success: false
      fork: Cancun

    assembler:
      title: "Code bytes: invalidPositions out of bound crash issue #2522"
      code:
        Push1  "0x01"    # 0: ok to jump
        Push1  "0x06"    # 2: jump to pc 6
        JumpI            # 4
        "0x695b00"       # 5: PUSH10 First byte is jumpDestOp but operand is too short
      success: false

when isMainModule:
  opMemoryMain()
