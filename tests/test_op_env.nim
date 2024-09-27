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
  macro_assembler, unittest2,
  stew/byteutils, ../nimbus/common/common,
  ../nimbus/[evm/state, constants],
  ../nimbus/db/ledger

proc opEnvMain*() =
  suite "Environmental Information Opcodes":
    assembler: # EVM bug reported in discord
      title: "stack's operator [] bug"
      code:
        Push1 "0x0A"
        Dup1
        ReturnDataSize
        Msize
        Address
        Gas
        StaticCall
        Call
      fork: London
      success: false
      memory: "0x0000000000000000000000000000000000000000000000000000000000000000"
      stack: "0x00"

    assembler: # CodeCopy OP
      title: "CODECOPY_1"
      code:
        Push1 "0x03" # size
        Push1 "0x08" # copy start pos
        Push1 "0x00" # mem start pos
        CodeCopy
        Stop
        Slt
        CallValue
        Jump
      memory: "0x1234560000000000000000000000000000000000000000000000000000000000"
      gasused: 18

    assembler: # CodeCopy OP
      title: "CODECOPY_2"
      code:
        Push1 "0x5E" # size
        Push1 "0x08" # copy start pos
        Push1 "0x00" # mem start pos
        CodeCopy
        Stop
        Push1 "0x00"
        Push1 "0x5f"
        Sstore
        Push1 "0x14"
        Push1 "0x00"
        Sload
        Push1 "0x1e"
        Push1 "0x20"
        Sload
        Push4 "0xabcddcba"
        Push1 "0x40"
        Sload
        JumpDest
        Mload
        Push1 "0x20"
        Add
        Push1 "0x0a"
        Mstore
        Sload
        Mload
        Push1 "0x40"
        Add
        Push1 "0x14"
        Mstore
        Sload
        Mload
        Push1 "0x60"
        Add
        Push1 "0x1e"
        Mstore
        Sload
        Mload
        Push1 "0x80"
        Add
        Push1 "0x28"
        Mstore
        Sload
        Push1 "0xa0"
        Mstore
        Sload
        Push1 "0x16"
        Push1 "0x48"
        Push1 "0x00"
        CodeCopy
        Push1 "0x16"
        Push1 "0x00"
        CallCode
        Push1 "0x00"
        Push1 "0x3f"
        Sstore
        Push2 "0x03e7"
        Jump
        Push1 "0x00"
        Sload
        Push1 "0x00"
        Mstore8
        Push1 "0x20"
        Mul
        CallDataLoad
        Push1 "0x20"
        Sload
      memory:
        "0x6000605F556014600054601E60205463ABCDDCBA6040545B51602001600A5254"
        "0x516040016014525451606001601E5254516080016028525460A0525460166048"
        "0x60003960166000F26000603F556103E756600054600053602002356020540000"
      gasUsed: 30

    assembler: # CodeCopy OP
      title: "CODECOPY_3"
        # cost for that:
        # 94 - data copied
        # 95 - new bytes allocated
      code:
        Push1 "0x5E"
        Push1 "0x08"
        Push1 "0x00"
        CodeCopy
        Stop
        "0x6000605f556014600054601e60205463abcddcba6040545b"
        "0x51602001600a5254516040016014525451606001601e52545160800160285254"
        "0x60a052546016604860003960166000f26000603f556103e75660005460005360"
        "0x20023500"
      memory:
        "0x6000605F556014600054601E60205463ABCDDCBA6040545B51602001600A5254"
        "0x516040016014525451606001601E5254516080016028525460A0525460166048"
        "0x60003960166000F26000603F556103E756600054600053602002350000000000"
      #assertEquals(10, program.getResult().getGasUsed());

    assembler: # CodeCopy OP
      title: "CODECOPY_4"
      code:
        Push1 "0x5E"
        Push1 "0x07"
        Push1 "0x00"
        CodeCopy
        Stop
        "0x6000605f556014600054601e60205463abcddcba6040545b51"
        "0x602001600a5254516040016014525451606001601e5254516080016028525460"
        "0xa052546016604860003960166000f26000603f556103e756600054600053602002351234"
      memory:
        "0x006000605F556014600054601E60205463ABCDDCBA6040545B51602001600A52"
        "0x54516040016014525451606001601E5254516080016028525460A05254601660"
        "0x4860003960166000F26000603F556103E7566000546000536020023512340000"
      #assertEquals(10, program.getResult().getGasUsed());

    assembler: # CodeCopy OP
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
        Stop
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

    assembler: # CodeCopy OP mal
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
    let
      acc = address"0xfbe0afcd7658ba86be41922059dd879c192d4c73"
      code = hexToSeqByte("0x0102030405060708090A0B0C0D0E0F" &
        "611234600054615566602054603E6000602073471FD3AD3E9EEADEEC4608B92D" &
        "16CE6B500704CC3C6000605f556014600054601e60205463abcddcba6040545b" &
        "51602001600a5254516040016014525451606001601e52545160800160285254" &
        "60a052546016604860003960166000f26000603f556103e756600054600053602002351234")

    assembler: # EXTCODECOPY OP
      title: "EXTCODECOPY_1"
      setup:
        vmState.mutateStateDB:
          db.setCode(acc, code)
      code:
        Push1 "0x04" # size
        Push1 "0x07" # code pos
        Push1 "0x00" # mem pos
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeCopy
        Stop
        Slt
        CallValue
        Jump
        Stop
      memory: "0x08090a0b00000000000000000000000000000000000000000000000000000000"

    assembler: # EXTCODECOPY OP
      title: "EXTCODECOPY_2"
      setup:
        vmState.mutateStateDB:
          db.setCode(acc, code)
      code:
        Push1 "0x3E"
        Push1 "0x07"
        Push1 "0x00"
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeCopy
        Stop
        "0x6000605f"
        "0x556014600054601e60205463abcddcba6040545b51602001600a525451604001"
        "0x6014525451606001601e5254516080016028525460a052546016604860003960"
        "0x166000f26000603f556103e75660005460005360200235602054"
      memory:
        "0x08090a0b0c0d0e0f611234600054615566602054603e6000602073471fd3ad3e"
        "0x9eeadeec4608b92d16ce6b500704cc3c6000605f556014600054601e60200000"

    assembler: # EXTCODECOPY OP
      title: "EXTCODECOPY_3"
      setup:
        vmState.mutateStateDB:
          db.setCode(acc, code)
      code:
        Push1 "0x5E"
        Push1 "0x07"
        Push1 "0x00"
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeCopy
        Stop
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
      setup:
        vmState.mutateStateDB:
          db.setCode(acc, code)
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
        Stop
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
        "0x471FD3AD3E9EEADEEC4608B92D16CE6B500704CC"

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
      setup:
        vmState.mutateStateDB:
          db.setCode(acc, code)
      code:
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeSize
        Stop
        "0x5E60076000396000605f"
        "0x556014600054601e60205463abcddcba6040545b51602001600a525451604001"
        "0x6014525451606001601e5254516080016028525460a052546016604860003960"
        "0x166000f26000603f556103e75660005460005360200235"
      stack: "0x94"

    assembler: # EIP2929 EXTCODESIZE OP
      title: "EIP2929 EXTCODESIZE_1"
      setup:
        vmState.mutateStateDB:
          db.setCode(acc, code)
      code:
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeSize
        Stop
      stack: "0x94"
      fork: Berlin
      gasused: 2603

    assembler: # EIP2929 EXTCODEHASH OP
      title: "EIP2929 EXTCODEHASH_1"
      setup:
        vmState.mutateStateDB:
          db.setCode(acc, code)
      code:
        Push20 "0xfbe0afcd7658ba86be41922059dd879c192d4c73"
        ExtCodeHash
        Stop
      stack:
        "0xc862129bffb73168481c6a51fd36afb8342887fbc5314c763ac731c732d7310c"
      fork: Berlin
      gasused: 2603

    assembler:
      title: "EIP-4399 PrevRandao 0"
      code:
        PrevRandao
        Stop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      fork: Paris

    assembler:
      title: "EIP-4399 PrevRandao: EMPTY_UNCLE_HASH"
      setup:
        vmState.blockCtx.prevRandao = EMPTY_UNCLE_HASH
      code:
        PrevRandao
        Stop
      stack:
        "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"
      fork: Paris

    assembler:
      title: "EIP-4844: BlobHash 1"
      code:
        Push1 "0x01"
        BlobHash
        Stop
      stack:
        "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
      fork: Cancun

    assembler:
      title: "EIP-4844: BlobHash 0"
      code:
        Push1 "0x00"
        BlobHash
        Stop
      stack:
        "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"
      fork: Cancun

    assembler:
      title: "EIP-4844: BlobHash 2"
      code:
        Push1 "0x02"
        BlobHash
        Stop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      fork: Cancun

    assembler:
      title: "EIP-4844: BlobHash 32 Bit high"
      code:
        Push4 "0xffffffff"
        BlobHash
        Stop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      fork: Cancun

    assembler:
      title: "EIP-4844: BlobHash 64 Bit high"
      code:
        Push8 "0xffffffffffffffff"
        BlobHash
        Stop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      fork: Cancun

    assembler:
      title: "EIP-4844: BlobHash 128 Bit high"
      code:
        Push16 "0xffffffffffffffffffffffffffffffff"
        BlobHash
        Stop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      fork: Cancun

    assembler:
      title: "EIP-4844: BlobHash 256 Bit high"
      code:
        Push32 "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        BlobHash
        Stop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      fork: Cancun

    assembler:
      title: "EIP-7516: BlobBaseFee"
      code:
        BlobBaseFee
        Stop
      stack:
        "0x0000000000000000000000000000000000000000000000000000000000000001"
      gasused: 2
      fork: Cancun

when isMainModule:
  opEnvMain()
