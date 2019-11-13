import
  macro_assembler, unittest2, macros,
  stew/byteutils, eth/common, stew/ranges

proc opMiscMain*() =
  suite "Misc Opcodes":
    setup:
      let (blockNumber, chainDB) = initDatabase()

    assembler: # LOG0 OP
      title: "Log0"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH1 "0x20"
        PUSH1 "0x00"
        LOG0
      memory:
        "0x1234"
      logs:
        (
          address: "0xc669eaad75042be84daaf9b461b0e868b9ac1871",
          data: "0x0000000000000000000000000000000000000000000000000000000000001234"
        )

    assembler: # LOG1 OP
      title: "Log1"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH2 "0x9999"
        PUSH1 "0x20"
        PUSH1 "0x00"
        LOG1
      memory:
        "0x1234"
      logs:
        (
          address: "0xc669eaad75042be84daaf9b461b0e868b9ac1871",
          topics: ["0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234"
        )

    assembler: # LOG2 OP
      title: "Log2"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH2 "0x9999"
        PUSH2 "0x6666"
        PUSH1 "0x20"
        PUSH1 "0x00"
        LOG2
      memory:
        "0x1234"
      logs:
        (
          address: "0xc669eaad75042be84daaf9b461b0e868b9ac1871",
          topics: ["0x6666", "0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234"
        )

    assembler: # LOG3 OP
      title: "Log3"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH2 "0x9999"
        PUSH2 "0x6666"
        PUSH2 "0x3333"
        PUSH1 "0x20"
        PUSH1 "0x00"
        LOG3
      memory:
        "0x1234"
      logs:
        (
          address: "0xc669eaad75042be84daaf9b461b0e868b9ac1871",
          topics: ["0x3333", "0x6666", "0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234"
        )

    assembler: # LOG4 OP
      title: "Log4"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH2 "0x9999"
        PUSH2 "0x6666"
        PUSH2 "0x3333"
        PUSH2 "0x5555"
        PUSH1 "0x20"
        PUSH1 "0x00"
        LOG4
      memory:
        "0x1234"
      logs:
        (
          address: "0xc669eaad75042be84daaf9b461b0e868b9ac1871",
          topics: ["0x5555", "0x3333", "0x6666", "0x9999"],
          data: "0x0000000000000000000000000000000000000000000000000000000000001234"
        )

    assembler: # STOP OP
      title: "STOP_1"
      code:
        PUSH1 "0x20"
        PUSH1 "0x30"
        PUSH1 "0x10"
        PUSH1 "0x30"
        PUSH1 "0x11"
        PUSH1 "0x23"
        STOP
      stack:
        "0x20"
        "0x30"
        "0x10"
        "0x30"
        "0x11"
        "0x23"

    assembler: # RETURN OP
      title: "RETURN_1"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH1 "0x20"
        PUSH1 "0x00"
        RETURN
      memory: "0x1234"
      output: "0x0000000000000000000000000000000000000000000000000000000000001234"

    assembler: # RETURN OP
      title: "RETURN_2"
      code:
        PUSH2 "0x1234"
        PUSH1 "0x00"
        MSTORE
        PUSH1 "0x20"
        PUSH1 "0x1F"
        RETURN
      memory:
        "0x1234"
        "0x00"
      output: "0x3400000000000000000000000000000000000000000000000000000000000000"

    assembler: # RETURN OP
      title: "RETURN_3"
      code:
        PUSH32 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
        PUSH1 "0x00"
        MSTORE
        PUSH1 "0x20"
        PUSH1 "0x00"
        RETURN
      memory: "0xa0b0c0d0e0f0a1b1c1d1e1f1a2b2c2d2e2f2a3b3c3d3e3f3a4b4c4d4e4f4a1b1"
      output: "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"

    assembler: # RETURN OP
      title: "RETURN_4"
      code:
        PUSH32 "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
        PUSH1 "0x00"
        MSTORE
        PUSH1 "0x20"
        PUSH1 "0x10"
        RETURN
      output: "0xE2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B100000000000000000000000000000000"
      memory:
        "0xA0B0C0D0E0F0A1B1C1D1E1F1A2B2C2D2E2F2A3B3C3D3E3F3A4B4C4D4E4F4A1B1"
        "0x00"
