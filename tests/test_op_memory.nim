import macro_assembler, unittest2, macros, strutils

proc opMemoryMain*() =
  suite "Memory Opcodes":
    setup:
      let (blockNumber, chainDB) = initDatabase()

    assembler: # PUSH1 OP
      title: "PUSH1"
      code:
        PUSH1 "0xa0"
      stack: "0x00000000000000000000000000000000000000000000000000000000000000A0"

    assembler: # PUSH2 OP
      title: "PUSH2"
      code:
        PUSH2 "0xa0b0"
      stack: "0x000000000000000000000000000000000000000000000000000000000000A0B0"

    assembler: # PUSH3 OP
      title: "PUSH3"
      code:
        PUSH3 "0xA0B0C0"
      stack: "0x0000000000000000000000000000000000000000000000000000000000A0B0C0"

    assembler: # PUSH4 OP
      title: "PUSH4"
      code:
        PUSH4 "0xA0B0C0D0"
      stack: "0x00000000000000000000000000000000000000000000000000000000A0B0C0D0"

    assembler: # PUSH5 OP
      title: "PUSH5"
      code:
        PUSH5 "0xA0B0C0D0E0"
      stack: "0x000000000000000000000000000000000000000000000000000000A0B0C0D0E0"

    assembler: # PUSH6 OP
      title: "PUSH6"
      code:
        PUSH6 "0xA0B0C0D0E0F0"
      stack: "0x0000000000000000000000000000000000000000000000000000A0B0C0D0E0F0"

    assembler: # PUSH7 OP
      title: "PUSH7"
      code:
        PUSH7 "0xA0B0C0D0E0F0A1"
      stack: "0x00000000000000000000000000000000000000000000000000A0B0C0D0E0F0A1"

    assembler: # PUSH8 OP
      title: "PUSH8"
      code:
        PUSH8 "0xA0B0C0D0E0F0A1B1"
      stack: "0x000000000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1"

    assembler: # PUSH9 OP
      title: "PUSH9"
      code:
        PUSH9 "0xA0B0C0D0E0F0A1B1C1"
      stack: "0x0000000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1"

    assembler: # PUSH10 OP
      title: "PUSH10"
      code:
        PUSH10 "0xA0B0C0D0E0F0A1B1C1D1"
      stack: "0x00000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1"

    assembler: # PUSH11 OP
      title: "PUSH11"
      code:
        PUSH11 "0xA0B0C0D0E0F0A1B1C1D1E1"
      stack: "0x000000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1"

    assembler: # PUSH12 OP
      title: "PUSH12"
      code:
        PUSH12 "0xA0B0C0D0E0F0A1B1C1D1E1F1"
      stack: "0x0000000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1"

    assembler: # PUSH13 OP
      title: "PUSH13"
      code:
        PUSH13 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2"
      stack: "0x00000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2"

    assembler: # PUSH14 OP
      title: "PUSH14"
      code:
        PUSH14 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2"
      stack: "0x000000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2"

    assembler: # PUSH15 OP
      title: "PUSH15"
      code:
        PUSH15 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2"
      stack: "0x0000000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2"

    assembler: # PUSH16 OP
      title: "PUSH16"
      code:
        PUSH16 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2"
      stack: "0x00000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2"

    assembler: # PUSH17 OP
      title: "PUSH17"
      code:
        PUSH17 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2"
      stack: "0x000000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2"

    assembler: # PUSH18 OP
      title: "PUSH18"
      code:
        PUSH18 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2"
      stack: "0x0000000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2"

    assembler: # PUSH19 OP
      title: "PUSH19"
      code:
        PUSH19 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3"
      stack: "0x00000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3"

    assembler: # PUSH20 OP
      title: "PUSH20"
      code:
        PUSH20 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3"
      stack: "0x000000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3"

    assembler: # PUSH21 OP
      title: "PUSH21"
      code:
        PUSH21 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3"
      stack: "0x0000000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3"

    assembler: # PUSH22 OP
      title: "PUSH22"
      code:
        PUSH22 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3"
      stack: "0x00000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3"

    assembler: # PUSH23 OP
      title: "PUSH23"
      code:
        PUSH23 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3"
      stack: "0x000000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3"

    assembler: # PUSH24 OP
      title: "PUSH24"
      code:
        PUSH24 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3"
      stack: "0x0000000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3"

    assembler: # PUSH25 OP
      title: "PUSH25"
      code:
        PUSH25 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4"
      stack: "0x00000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4"

    assembler: # PUSH26 OP
      title: "PUSH26"
      code:
        PUSH26 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4"
      stack: "0x000000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4"

    assembler: # PUSH27 OP
      title: "PUSH27"
      code:
        PUSH27 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4"
      stack: "0x0000000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4"

    assembler: # PUSH28 OP
      title: "PUSH28"
      code:
        PUSH28 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4"
      stack: "0x00000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4"

    assembler: # PUSH29 OP
      title: "PUSH29"
      code:
        PUSH29 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4"
      stack: "0x000000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4"

    assembler: # PUSH30 OP
      title: "PUSH30"
      code:
        PUSH30 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4"
      stack: "0x0000A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4"

    assembler: # PUSH31 OP
      title: "PUSH31"
      code:
        PUSH31 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1"
      stack: "0x00A0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1"

    assembler: # PUSH32 OP
      title: "PUSH32"
      code:
        PUSH32 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
      stack: "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"

    # macro assembler prevented this
    #assembler: # PUSHN OP not enough data
    #  title: "PUSHN_1"
    #  code:
    #    PUSH2 "0xAA"
    #  stack: "0x000000000000000000000000000000000000000000000000000000000000AA00"
    #  success: false
    #
    #assembler: # PUSHN OP not enough data
    #  title: "PUSHN_2"
    #  code:
    #    PUSH32 "0xAABB"
    #  stack: "0xAABB000000000000000000000000000000000000000000000000000000000000"
    #  success: false

    assembler: # POP OP
      title: "POP_1"
      code:
        PUSH2 "0x0000"
        PUSH1 "0x01"
        PUSH3 "0x000002"
        POP
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000001"

    assembler: # POP OP
      title: "POP_2"
      code:
        PUSH2 "0x0000"
        PUSH1 "0x01"
        PUSH3 "0x000002"
        POP
        POP
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler:# POP OP mal data
      title: "POP_3"
      code:
        PUSH2 "0x0000"
        PUSH1 "0x01"
        PUSH3 "0x000002"
        POP
        POP
        POP
        POP
      success: false

    macro generateDUPS(): untyped =
      result = newStmtList()

      for i in 1 .. 16:
        let title = newStmtList(newLit("DUP_" & $i))
        let pushIdent = ident("PUSH1")
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
        DUP1
      success: false

    macro generateSWAPS(): untyped =
      result = newStmtList()

      for i in 1 .. 16:
        let title = newStmtList(newLit("SWAP_" & $i))
        let pushIdent = ident("PUSH1")
        var body = newStmtList()
        var stack = newStmtList()

        for x in countDown(i, 0):
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
        SWAP1
      success: false

    assembler: # MSTORE OP
      title: "MSTORE_1"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
      memory: "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler: # MSTORE OP
      title: "MSTORE_2"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH2 "0x5566"
        PUSH1 "0x20"
        MSTORE
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000001234"
        "0x0000000000000000000000000000000000000000000000000000000000005566"

    assembler: # MSTORE OP
      title: "MSTORE_3"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH2 "0x5566"
        PUSH1 "0x20"
        MSTORE
        PUSH2 "0x8888"
        PUSH1 "0x00"
        MSTORE
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000008888"
        "0x0000000000000000000000000000000000000000000000000000000000005566"

    assembler: # MSTORE OP
      title: "MSTORE_4"
      code:
        PUSH2 "0x1234"
        PUSH1 "0xA0"
        MSTORE
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler: # MSTORE OP
      title: "MSTORE_5"
      code:
        PUSH2 "0x1234"
        MSTORE
      success: false
      stack: "0x1234"

    assembler: # MLOAD OP
      title: "MLOAD_1"
      code:
        PUSH1 "0x00"
        MLOAD
      memory: "0x0000000000000000000000000000000000000000000000000000000000000000"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # MLOAD OP
      title: "MLOAD_2"
      code:
        PUSH1 "0x22"
        MLOAD
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # MLOAD OP
      title: "MLOAD_3"
      code:
        PUSH1 "0x20"
        MLOAD
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # MLOAD OP
      title: "MLOAD_4"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x20"
        MSTORE
        PUSH1 "0x20"
        MLOAD
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000001234"
      stack: "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler: # MLOAD OP
      title: "MLOAD_5"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x20"
        MSTORE
        PUSH1 "0x1F"
        MLOAD
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0000000000000000000000000000000000000000000000000000000000001234"
      stack: "0x0000000000000000000000000000000000000000000000000000000000000012"

    assembler: # MLOAD OP mal data
      title: "MLOAD_6"
      code:
        MLOAD
      success: false

    assembler: # MSTORE8 OP
      title: "MSTORE8_1"
      code:
        PUSH1 "0x11"
        PUSH1 "0x00"
        MSTORE8
      memory: "0x1100000000000000000000000000000000000000000000000000000000000000"

    assembler: # MSTORE8 OP
      title: "MSTORE8_2"
      code:
        PUSH1 "0x22"
        PUSH1 "0x01"
        MSTORE8
      memory: "0x0022000000000000000000000000000000000000000000000000000000000000"

    assembler: # MSTORE8 OP
      title: "MSTORE8_3"
      code:
        PUSH1 "0x22"
        PUSH1 "0x21"
        MSTORE8
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0022000000000000000000000000000000000000000000000000000000000000"

    assembler: # MSTORE8 OP mal
      title: "MSTORE8_4"
      code:
        PUSH1 "0x22"
        MSTORE8
      success: false
      stack: "0x22"

    assembler: # SSTORE OP
      title: "SSTORE_1"
      code:
        PUSH1 "0x22"
        PUSH1 "0xAA"
        SSTORE
      storage:
        "0xAA": "0x22"

    assembler: # SSTORE OP
      title: "SSTORE_2"
      code:
        PUSH1 "0x22"
        PUSH1 "0xAA"
        SSTORE
        PUSH1 "0x22"
        PUSH1 "0xBB"
        SSTORE
      storage:
        "0xAA": "0x22"
        "0xBB": "0x22"

    assembler: # SSTORE OP
      title: "SSTORE_3"
      code:
        PUSH1 "0x22"
        SSTORE
      success: false
      stack: "0x22"
  #[
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_1"
      code: "60006000556000600055"
      fork: constantinople
      # assertEquals(412, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_2"
      code: "60006000556001600055"
      fork: constantinople
      # assertEquals(20212, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_3"
      code: "60016000556000600055"
      fork: constantinople
      # assertEquals(20212, program.getResult().getGasUsed())
      # assertEquals(19800, program.getResult().getFutureRefund())

    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_4"
      code: "60016000556002600055"
      fork: constantinople
      # assertEquals(20212, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_5"
      code: "60016000556001600055"
      fork: constantinople
      # assertEquals(20212, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    # Sets Storage row on "cow" address:
    # 0: 1
    # private void setStorageToOne(VM vm) {
    #       # Sets storage value to 1 and commits
    #           code: "60006000556001600055"
    #           fork: constantinople
    #       invoke.getRepository().commit()
    #       invoke.setOrigRepository(invoke.getRepository())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_6"
      code: "60006000556000600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(15000, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_7"
      code: "60006000556001600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(4800, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_8"
      code: "60006000556002600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_9"
      code: "60026000556000600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(15000, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_10"
      code: "60026000556003600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_11"
      code: "60026000556001600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(4800, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_12"
      code: "60026000556002600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_13"
      code: "60016000556000600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(15000, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_14"
      code: "60016000556002600055"
      fork: constantinople
      # assertEquals(5212, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_15"
      code: "60016000556001600055"
      fork: constantinople
      # assertEquals(412, program.getResult().getGasUsed())
      # assertEquals(0, program.getResult().getFutureRefund())

    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_16"
      code: "600160005560006000556001600055"
      fork: constantinople
      # assertEquals(40218, program.getResult().getGasUsed())
      # assertEquals(19800, program.getResult().getFutureRefund())

    setStorageToOne(vm)
    assembler: # SSTORE EIP1283
      title: "SSTORE_NET_17"
      code: "600060005560016000556000600055"
      fork: constantinople
      # assertEquals(10218, program.getResult().getGasUsed())
      # assertEquals(19800, program.getResult().getFutureRefund())
  ]#
    assembler: # SLOAD OP
      title: "SLOAD_1"
      code:
        PUSH1 "0xAA"
        SLOAD
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # SLOAD OP
      title: "SLOAD_2"
      code:
        PUSH1 "0x22"
        PUSH1 "0xAA"
        SSTORE
        PUSH1 "0xAA"
        SLOAD
      stack: "0x0000000000000000000000000000000000000000000000000000000000000022"

    assembler: # SLOAD OP
      title: "SLOAD_3"
      code:
        PUSH1 "0x22"
        PUSH1 "0xAA"
        SSTORE
        PUSH1 "0x33"
        PUSH1 "0xCC"
        SSTORE
        PUSH1 "0xCC"
        SLOAD
      stack: "0x0000000000000000000000000000000000000000000000000000000000000033"

    assembler: # SLOAD OP
      title: "SLOAD_4"
      code: SLOAD
      success: false

    assembler: # PC OP
      title: "PC_1"
      code: PC
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # PC OP
      title: "PC_2"
      code:
        PUSH1 "0x22"
        PUSH1 "0xAA"
        MSTORE
        PUSH1 "0xAA"
        SLOAD
        PC
      stack:
        "0x00"
        "0x0000000000000000000000000000000000000000000000000000000000000008"
      memory:
        "0x00"
        "0x00"
        "0x00"
        "0x00"
        "0x00"
        "0x00"
        "0x0000000000000000002200000000000000000000000000000000000000000000"

    assembler: # JUMP OP mal data
      title: "JUMP_1"
      code:
        PUSH1 "0xAA"
        PUSH1 "0xBB"
        PUSH1 "0x0E"
        JUMP
        PUSH1 "0xCC"
        PUSH1 "0xDD"
        PUSH1 "0xEE"
        JUMPDEST
        PUSH1 "0xFF"
      stack:
        "0xaa"
        "0x00000000000000000000000000000000000000000000000000000000000000bb"
      success: false

    assembler: # JUMP OP mal data
      title: "JUMP_2"
      code:
        PUSH1 "0x0C"
        PUSH1 "0x0C"
        SWAP1
        JUMP
        PUSH1 "0xCC"
        PUSH1 "0xDD"
        PUSH1 "0xEE"
        PUSH1 "0xFF"
      success: false
      stack : "0x0C"

    assembler: # JUMPI OP
      title: "JUMPI_1"
      code:
        PUSH1 "0x01"
        PUSH1 "0x05"
        JUMPI
        JUMPDEST
        PUSH1 "0xCC"
      stack: "0x00000000000000000000000000000000000000000000000000000000000000CC"

    assembler: # JUMPI OP
      title: "JUMPI_2"
      code:
        PUSH4 "0x00000000"
        PUSH1 "0x44"
        JUMPI
        PUSH1 "0xCC"
        PUSH1 "0xDD"
      stack:
        "0x00000000000000000000000000000000000000000000000000000000000000CC"
        "0x00000000000000000000000000000000000000000000000000000000000000DD"

    assembler: # JUMPI OP mal
      title: "JUMPI_3"
      code:
        PUSH1 "0x01"
        JUMPI
      success: false
      stack: "0x01"

    assembler: # JUMPI OP mal
      title: "JUMPI_4"
      code:
        PUSH1 "0x01"
        PUSH1 "0x22"
        SWAP1
        SWAP1
        JUMPI
      success: false

    assembler: # JUMP OP mal data
      title: "JUMPDEST_1"
      code:
        PUSH1 "0x23"
        PUSH1 "0x08"
        JUMP
        PUSH1 "0x01"
        JUMPDEST
        PUSH1 "0x02"
        SSTORE
      storage:
        "0x02": "0x00"
      stack: "0x23"
      success: false

    # success or not?
    assembler: # JUMPDEST OP for JUMPI
      title: "JUMPDEST_2"
      code:
        PUSH1 "0x23"
        PUSH1 "0x01"
        PUSH1 "0x09"
        JUMPI
        PUSH1 "0x01"
        JUMPDEST
        PUSH1 "0x02"
        SSTORE
      #success: false
      storage:
        "0x02": "0x23"

    assembler: # MSIZE OP
      title: "MSIZE_1"
      code:
        MSIZE
      stack: "0x0000000000000000000000000000000000000000000000000000000000000000"

    assembler: # MSIZE OP
      title: "MSIZE_2"
      code:
        PUSH1 "0x20"
        PUSH1 "0x30"
        MSTORE
        MSIZE
      stack:
        "0x60"
      memory:
        "0x00"
        "0x00"
        "0x0000000000000000000000000000002000000000000000000000000000000000"

when isMainModule:
  opMemoryMain()
