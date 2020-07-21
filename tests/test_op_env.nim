import
  macro_assembler, unittest2, macros,
  stew/byteutils, eth/common, ../nimbus/db/state_db,
  ../nimbus/db/db_chain

proc opEnvMain*() =
  suite "Environmental Information Opcodes":
    setup:
      let (blockNumber, chainDB) = initDatabase()

    assembler: # CODECOPY OP
      title: "CODECOPY_1"
      code:
        PUSH1 "0x03" # size
        PUSH1 "0x08" # copy start pos
        PUSH1 "0x00" # mem start pos
        CODECOPY
        STOP
        SLT
        CALLVALUE
        JUMP
      memory: "0x1234560000000000000000000000000000000000000000000000000000000000"
      # assertEquals(6, gas); ??

    assembler: # CODECOPY OP
      title: "CODECOPY_2"
      code:
        PUSH1 "0x5E" # size
        PUSH1 "0x08" # copy start pos
        PUSH1 "0x00" # mem start pos
        CODECOPY
        STOP
        PUSH1 "0x00"
        PUSH1 "0x5f"
        SSTORE
        PUSH1 "0x14"
        PUSH1 "0x00"
        SLOAD
        PUSH1 "0x1e"
        PUSH1 "0x20"
        SLOAD
        PUSH4 "0xabcddcba"
        PUSH1 "0x40"
        SLOAD
        JUMPDEST
        MLOAD
        PUSH1 "0x20"
        ADD
        PUSH1 "0x0a"
        MSTORE
        SLOAD
        MLOAD
        PUSH1 "0x40"
        ADD
        PUSH1 "0x14"
        MSTORE
        SLOAD
        MLOAD
        PUSH1 "0x60"
        ADD
        PUSH1 "0x1e"
        MSTORE
        SLOAD
        MLOAD
        PUSH1 "0x80"
        ADD
        PUSH1 "0x28"
        MSTORE
        SLOAD
        PUSH1 "0xa0"
        MSTORE
        SLOAD
        PUSH1 "0x16"
        PUSH1 "0x48"
        PUSH1 "0x00"
        CODECOPY
        PUSH1 "0x16"
        PUSH1 "0x00"
        CALLCODE
        PUSH1 "0x00"
        PUSH1 "0x3f"
        SSTORE
        PUSH2 "0x03e7"
        JUMP
        PUSH1 "0x00"
        SLOAD
        PUSH1 "0x00"
        MSTORE8
        PUSH1 "0x20"
        MUL
        CALLDATALOAD
        PUSH1 "0x20"
        SLOAD
      memory:
        "0x6000605F556014600054601E60205463ABCDDCBA6040545B51602001600A5254"
        "0x516040016014525451606001601E5254516080016028525460A0525460166048"
        "0x60003960166000F26000603F556103E756600054600053602002356020540000"
      #assertEquals(10, gas); ??

    assembler: # CODECOPY OP
      title: "CODECOPY_3"
        # cost for that:
        # 94 - data copied
        # 95 - new bytes allocated
      code:
        Push1 "0x5E"
        Push1 "0x08"
        Push1 "0x00"
        CodeCopy
        STOP
        "0x6000605f556014600054601e60205463abcddcba6040545b"
        "0x51602001600a5254516040016014525451606001601e52545160800160285254"
        "0x60a052546016604860003960166000f26000603f556103e75660005460005360"
        "0x20023500"
      memory:
        "0x6000605F556014600054601E60205463ABCDDCBA6040545B51602001600A5254"
        "0x516040016014525451606001601E5254516080016028525460A0525460166048"
        "0x60003960166000F26000603F556103E756600054600053602002350000000000"
      #assertEquals(10, program.getResult().getGasUsed());

    assembler: # CODECOPY OP
      title: "CODECOPY_4"
      code:
        Push1 "0x5E"
        Push1 "0x07"
        Push1 "0x00"
        CodeCopy
        STOP
        "0x6000605f556014600054601e60205463abcddcba6040545b51"
        "0x602001600a5254516040016014525451606001601e5254516080016028525460"
        "0xa052546016604860003960166000f26000603f556103e756600054600053602002351234"
      memory:
        "0x006000605F556014600054601E60205463ABCDDCBA6040545B51602001600A52"
        "0x54516040016014525451606001601E5254516080016028525460A05254601660"
        "0x4860003960166000F26000603F556103E7566000546000536020023512340000"
      #assertEquals(10, program.getResult().getGasUsed());

    assembler: # CODECOPY OP
      title: "CODECOPY_5"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Sload
        Push2 "0x5566"
        Push1 "0x20"
        Sload
        Push1 "0x70"
        Push1 "0x00"
        Push1 "0x20"
        CodeCopy
        STOP
        "0x6000605f55601460"
        "0x0054601e60205463abcddcba6040545b51602001600a525451604001"
        "0x6014525451606001601e5254516080016028525460a0525460166048"
        "0x60003960166000f26000603f556103e75660005460005360200235123400"
      stack:
        "0x1234"
        "0x00"
        "0x5566"
        "0x00"
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x61123460005461556660205460706000602039006000605f556014600054601e"
        "0x60205463abcddcba6040545b51602001600a5254516040016014525451606001"
        "0x601e5254516080016028525460a052546016604860003960166000f26000603f"
        "0x556103e756600054600053602002351200000000000000000000000000000000"

    assembler: # CODECOPY OP mal
      title: "CODECOPY_6"
      code:
        "0x605E6007396000605f556014600054601e60205463abcddcba604054"
        "0x5b51602001600a5254516040016014525451606001601e5254516080"
        "0x016028525460a052546016604860003960166000f26000603f556103"
        "0xe756600054600053602002351234"
      success: false
      stack:
        "0x5e"
        "0x07"

  suite "Environmental Information Opcodes 2":
    setup:
      let (blockNumber, chainDB) = initDatabase()
      var acc: EthAddress
      hexToByteArray("0xfbe0afcd7658ba86be41922059dd879c192d4c73", acc)
      var
        parent = chainDB.getBlockHeader(blockNumber - 1)
        stateDB = newAccountStateDB(chainDB.db, parent.stateRoot, false)
        code = hexToSeqByte("0x0102030405060708090A0B0C0D0E0F" &
          "611234600054615566602054603E6000602073471FD3AD3E9EEADEEC4608B92D" &
          "16CE6B500704CC3C6000605f556014600054601e60205463abcddcba6040545b" &
          "51602001600a5254516040016014525451606001601e52545160800160285254" &
          "60a052546016604860003960166000f26000603f556103e756600054600053602002351234")

      stateDB.setCode(acc, code)
      parent.stateRoot = stateDB.rootHash
      chainDB.setHead(parent, true)

    assembler: # EXTCODECOPY OP
      title: "EXTCODECOPY_1"
      code:
        Push1 "0x04" # size
        Push1 "0x07" # code pos
        Push1 "0x00" # mem pos
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeCopy
        STOP
        Slt
        CallValue
        Jump
        Stop
      memory: "0x08090a0b00000000000000000000000000000000000000000000000000000000"

    assembler: # EXTCODECOPY OP
      title: "EXTCODECOPY_2"
      code:
        Push1 "0x3E"
        Push1 "0x07"
        Push1 "0x00"
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeCopy
        STOP
        "0x6000605f"
        "0x556014600054601e60205463abcddcba6040545b51602001600a525451604001"
        "0x6014525451606001601e5254516080016028525460a052546016604860003960"
        "0x166000f26000603f556103e75660005460005360200235602054"
      memory:
        "0x08090a0b0c0d0e0f611234600054615566602054603e6000602073471fd3ad3e"
        "0x9eeadeec4608b92d16ce6b500704cc3c6000605f556014600054601e60200000"

    assembler: # EXTCODECOPY OP
      title: "EXTCODECOPY_3"
      code:
        Push1 "0x5E"
        Push1 "0x07"
        Push1 "0x00"
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeCopy
        STOP
        "0x6000605f"
        "0x556014600054601e60205463abcddcba6040545b51602001600a525451604001"
        "0x6014525451606001601e5254516080016028525460a052546016604860003960"
        "0x166000f26000603f556103e75660005460005360200235"
      memory:
        "0x08090a0b0c0d0e0f611234600054615566602054603e6000602073471fd3ad3e"
        "0x9eeadeec4608b92d16ce6b500704cc3c6000605f556014600054601e60205463"
        "0xabcddcba6040545b51602001600a5254516040016014525451606001601e0000"

    assembler: # EXTCODECOPY OP
      title: "EXTCODECOPY_4"
      code:
        Push2 "0x1234"
        Push1 "0x00"
        Sload
        Push2 "0x5566"
        Push1 "0x20"
        Sload
        Push1 "0x3E"
        Push1 "0x00"
        Push1 "0x20"
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeCopy
        STOP
        "0x6000605f556014600054601e60205463abcddcba6040545b"
        "0x51602001600a5254516040016014525451606001601e52545160800160285254"
        "0x60a052546016604860003960166000f26000603f556103e756600054600053602002351234"
      stack:
        "0x1234"
        "0x00"
        "0x5566"
        "0x00"
      memory:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
        "0x0102030405060708090a0b0c0d0e0f611234600054615566602054603e600060"
        "0x2073471fd3ad3e9eeadeec4608b92d16ce6b500704cc3c6000605f5560140000"

    assembler: # EXTCODECOPY OP mal
      title: "EXTCODECOPY_5"
      code:
        Push1 "0x5E"
        Push1 "0x07"
        Push20 "0x471FD3AD3E9EEADEEC4608B92D16CE6B500704CC"
        ExtCodeCopy
      success: false
      stack:
        "0x5E"
        "0x07"

    assembler: # CODESIZE OP
      title: "CODESIZE_1"
      code:
        "0x385E60076000396000605f556014600054601e60205463abcddcba6040545b51"
        "0x602001600a5254516040016014525451606001601e5254516080016028525460"
        "0xa052546016604860003960166000f26000603f556103e75660005460005360200235"
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000062"
      success: false

    # 0x94 == 148 bytes
    assembler: # EXTCODESIZE OP
      title: "EXTCODESIZE_1"
      code:
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeSize
        STOP
        "0x5E60076000396000605f"
        "0x556014600054601e60205463abcddcba6040545b51602001600a525451604001"
        "0x6014525451606001601e5254516080016028525460a052546016604860003960"
        "0x166000f26000603f556103e75660005460005360200235"
      stack: "0x94"
