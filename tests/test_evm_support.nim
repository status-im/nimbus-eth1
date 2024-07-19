# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[importutils, sequtils],
  unittest2,
  stew/byteutils,
  eth/keys,
  ../nimbus/common,
  ../nimbus/transaction,
  ../nimbus/evm/types,
  ../nimbus/evm/state,
  ../nimbus/evm/evm_errors,
  ../nimbus/evm/stack,
  ../nimbus/evm/memory,
  ../nimbus/evm/code_stream,
  ../nimbus/evm/internals,
  ../nimbus/constants,
  ../nimbus/core/pow/header,
  ../nimbus/db/ledger,
  ../nimbus/transaction/call_evm

template testPush(value: untyped, expected: untyped): untyped =
  privateAccess(EvmStack)
  var stack = EvmStack.init()
  check stack.push(value).isOk
  check(stack.values == @[expected])

func toBytes(s: string): seq[byte] =
  cast[seq[byte]](s)

func bigEndianToInt(value: openArray[byte]): UInt256 =
  result.initFromBytesBE(value)

proc runStackTests() =
  suite "Stack tests":
    test "push only valid":
      testPush(0'u, 0.u256)
      testPush(UINT_256_MAX, UINT_256_MAX)
      testPush("ves".toBytes, "ves".toBytes.bigEndianToInt)

    test "push does not allow stack to exceed 1024":
      var stack = EvmStack.init()
      for z in 0 ..< 1024:
        check stack.push(z.uint).isOk
      check(stack.len == 1024)
      check stack.push(1025).error.code == EvmErrorCode.StackFull

    test "dup does not allow stack to exceed 1024":
      var stack = EvmStack.init()
      check stack.push(1.u256).isOk
      for z in 0 ..< 1023:
        check stack.dup(1).isOk
      check(stack.len == 1024)
      check stack.dup(1).error.code == EvmErrorCode.StackFull

    test "pop returns latest stack item":
      var stack = EvmStack.init()
      for element in @[1'u, 2'u, 3'u]:
        check stack.push(element).isOk
      check(stack.popInt.get == 3.u256)

    test "swap correct":
      privateAccess(EvmStack)
      var stack = EvmStack.init()
      for z in 0 ..< 5:
        check stack.push(z.uint).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256])
      check stack.swap(3).isOk
      check(stack.values == @[0.u256, 4.u256, 2.u256, 3.u256, 1.u256])
      check stack.swap(1).isOk
      check(stack.values == @[0.u256, 4.u256, 2.u256, 1.u256, 3.u256])

    test "dup correct":
      privateAccess(EvmStack)
      var stack = EvmStack.init()
      for z in 0 ..< 5:
        check stack.push(z.uint).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256])
      check stack.dup(1).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256, 4.u256])
      check stack.dup(5).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256, 4.u256, 1.u256])

    test "pop raises InsufficientStack appropriately":
      var stack = EvmStack.init()
      check stack.popInt().error.code == EvmErrorCode.StackInsufficient

    test "swap raises InsufficientStack appropriately":
      var stack = EvmStack.init()
      check stack.swap(0).error.code == EvmErrorCode.StackInsufficient

    test "dup raises InsufficientStack appropriately":
      var stack = EvmStack.init()
      check stack.dup(0).error.code == EvmErrorCode.StackInsufficient

    test "binary operations raises InsufficientStack appropriately":
      # https://github.com/status-im/nimbus/issues/31
      # ./tests/fixtures/VMTests/vmArithmeticTest/mulUnderFlow.json

      var stack = EvmStack.init()
      check stack.push(123).isOk
      check stack.popInt(2).error.code == EvmErrorCode.StackInsufficient

proc memory32(): EvmMemory =
  result = EvmMemory.init(32)

proc memory128(): EvmMemory =
  result = EvmMemory.init(123)

proc runMemoryTests() =
  suite "Memory tests":
    test "write":
      var mem = memory32()
      # Test that write creates 32byte string == value padded with zeros
      check mem.write(startPos = 0, value = @[1.byte, 0.byte, 1.byte, 0.byte]).isOk
      check(mem.bytes == @[1.byte, 0.byte, 1.byte, 0.byte].concat(repeat(0.byte, 28)))

    test "write rejects values beyond memory size":
      var mem = memory128()
      check mem.write(startPos = 128, value = @[1.byte, 0.byte, 1.byte, 0.byte]).error.code ==
        EvmErrorCode.MemoryFull
      check mem.write(startPos = 128, value = 1.byte).error.code ==
        EvmErrorCode.MemoryFull

    test "extends appropriately extends memory":
      var mem = EvmMemory.init()
      # Test extends to 32 byte array: 0 < (start_position + size) <= 32
      mem.extend(startPos = 0, size = 10)
      check(mem.bytes == repeat(0.byte, 32))
      # Test will extend past length if params require: 32 < (start_position + size) <= 64
      mem.extend(startPos = 28, size = 32)
      check(mem.bytes == repeat(0.byte, 64))
      # Test won't extend past length unless params require: 32 < (start_position + size) <= 64
      mem.extend(startPos = 48, size = 10)
      check(mem.bytes == repeat(0.byte, 64))

    test "read returns correct bytes":
      var mem = memory32()
      check mem.write(startPos = 5, value = @[1.byte, 0.byte, 1.byte, 0.byte]).isOk
      check(@(mem.read(startPos = 5, size = 4)) == @[1.byte, 0.byte, 1.byte, 0.byte])
      check(@(mem.read(startPos = 6, size = 4)) == @[0.byte, 1.byte, 0.byte, 0.byte])
      check(@(mem.read(startPos = 1, size = 3)) == @[0.byte, 0.byte, 0.byte])

proc runCodeStreamTests() =
  suite "Codestream tests":
    test "accepts bytes":
      let codeStream = CodeStream.init("\x01")
      check(codeStream.len == 1)

    test "next returns the correct opcode":
      var codeStream = CodeStream.init("\x01\x02\x30")
      check(codeStream.next == Op.ADD)
      check(codeStream.next == Op.MUL)
      check(codeStream.next == Op.ADDRESS)

    test "peek returns next opcode without changing location":
      var codeStream = CodeStream.init("\x01\x02\x30")
      check(codeStream.pc == 0)
      check(codeStream.peek == Op.ADD)
      check(codeStream.pc == 0)
      check(codeStream.next == Op.ADD)
      check(codeStream.pc == 1)
      check(codeStream.peek == Op.MUL)
      check(codeStream.pc == 1)

    test "stop opcode is returned when end reached":
      var codeStream = CodeStream.init("\x01\x02")
      discard codeStream.next
      discard codeStream.next
      check(codeStream.next == Op.STOP)

    test "[] returns opcode":
      let codeStream = CodeStream.init("\x01\x02\x30")
      check(codeStream[0] == Op.ADD)
      check(codeStream[1] == Op.MUL)
      check(codeStream[2] == Op.ADDRESS)

    test "isValidOpcode invalidates after PUSHXX":
      var codeStream = CodeStream.init("\x02\x60\x02\x04")
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(not codeStream.isValidOpcode(2))
      check(codeStream.isValidOpcode(3))
      check(not codeStream.isValidOpcode(4))

    test "isValidOpcode 0":
      var codeStream = CodeStream.init(
        @[2.byte, 3.byte, 0x72.byte].concat(repeat(4.byte, 32)).concat(@[5.byte])
      )
      # valid: 0 - 2 :: 22 - 35
      # invalid: 3-21 (PUSH19) :: 36+ (too long)
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(codeStream.isValidOpcode(2))
      check(not codeStream.isValidOpcode(3))
      check(not codeStream.isValidOpcode(21))
      check(codeStream.isValidOpcode(22))
      check(codeStream.isValidOpcode(35))
      check(not codeStream.isValidOpcode(36))

    test "isValidOpcode 1":
      let test = @[2.byte, 3.byte, 0x7d.byte]
        .concat(repeat(4.byte, 32))
        .concat(@[5.byte, 0x7e.byte])
        .concat(repeat(4.byte, 35))
        .concat(@[1.byte, 0x61.byte, 1.byte, 1.byte, 1.byte])
      var codeStream = CodeStream.init(test)
      # valid: 0 - 2 :: 33 - 36 :: 68 - 73 :: 76
      # invalid: 3 - 32 (PUSH30) :: 37 - 67 (PUSH31) :: 74, 75 (PUSH2) :: 77+ (too long)
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(codeStream.isValidOpcode(2))
      check(not codeStream.isValidOpcode(3))
      check(not codeStream.isValidOpcode(32))
      check(codeStream.isValidOpcode(33))
      check(codeStream.isValidOpcode(36))
      check(not codeStream.isValidOpcode(37))
      check(not codeStream.isValidOpcode(67))
      check(codeStream.isValidOpcode(68))
      check(codeStream.isValidOpcode(71))
      check(codeStream.isValidOpcode(72))
      check(codeStream.isValidOpcode(73))
      check(not codeStream.isValidOpcode(74))
      check(not codeStream.isValidOpcode(75))
      check(codeStream.isValidOpcode(76))
      check(not codeStream.isValidOpcode(77))

    test "right number of bytes invalidates":
      var codeStream = CodeStream.init("\x02\x03\x60\x02\x02")
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(codeStream.isValidOpcode(2))
      check(not codeStream.isValidOpcode(3))
      check(codeStream.isValidOpcode(4))
      check(not codeStream.isValidOpcode(5))

proc initGasMeter(startGas: GasInt): GasMeter =
  result.init(startGas)

proc gasMeters(): seq[GasMeter] =
  @[initGasMeter(10), initGasMeter(100), initGasMeter(999)]

template runTest(body: untyped) =
  var res = gasMeters()
  for gasMeter {.inject.} in res.mitems:
    let StartGas {.inject.} = gasMeter.gasRemaining
    body

proc runGasMeterTests() =
  suite "GasMeter tests":
    test "consume spends":
      runTest:
        check(gasMeter.gasRemaining == StartGas)
        let consume = StartGas
        check gasMeter.consumeGas(consume, "0").isOk
        check(gasMeter.gasRemaining - (StartGas - consume) == 0)

    test "consume errors":
      runTest:
        check(gasMeter.gasRemaining == StartGas)
        check gasMeter.consumeGas(StartGas + 1, "").error.code == EvmErrorCode.OutOfGas

    test "return refund works correctly":
      runTest:
        check(gasMeter.gasRemaining == StartGas)
        check(gasMeter.gasRefunded == 0)
        check gasMeter.consumeGas(5, "").isOk
        check(gasMeter.gasRemaining == StartGas - 5)
        gasMeter.returnGas(5)
        check(gasMeter.gasRemaining == StartGas)
        gasMeter.refundGas(5)
        check(gasMeter.gasRefunded == 5)

func toAddress(n: int): EthAddress =
  result[19] = n.byte

func toAddress(a, b: int): EthAddress =
  result[18] = a.byte
  result[19] = b.byte

func toAddress(a, b, c: int): EthAddress =
  result[17] = a.byte
  result[18] = b.byte
  result[19] = c.byte

proc runMiscTests() =
  suite "Misc test suite":
    test "EthAddress to int":
      check toAddress(0xff).toInt == 0xFF
      check toAddress(0x10, 0x0).toInt == 0x1000
      check toAddress(0x10, 0x0, 0x0).toInt == 0x100000

    test "calcGasLimitEIP1559":
      type GLT = object
        limit: GasInt
        max: GasInt
        min: GasInt

      const testData = [
        GLT(limit: 20000000, max: 20019530, min: 19980470),
        GLT(limit: 40000000, max: 40039061, min: 39960939),
      ]

      for x in testData:
        # Increase
        var have = calcGasLimit1559(x.limit, 2 * x.limit)
        var want = x.max
        check have == want

        # Decrease
        have = calcGasLimit1559(x.limit, 0)
        want = x.min
        check have == want

        # Small decrease
        have = calcGasLimit1559(x.limit, x.limit - 1)
        want = x.limit - 1
        check have == want

        # Small increase
        have = calcGasLimit1559(x.limit, x.limit + 1)
        want = x.limit + 1
        check have == want

        # No change
        have = calcGasLimit1559(x.limit, x.limit)
        want = x.limit
        check have == want

const
  data = [
    0x5b.uint8, 0x5a, 0x5a, 0x30, 0x30, 0x30, 0x30, 0x72, 0x00, 0x00, 0x00, 0x58, 0x58,
    0x24, 0x58, 0x58, 0x3a, 0x19, 0x75, 0x75, 0x2e, 0x2e, 0x2e, 0x2e, 0xec, 0x9f, 0x69,
    0x67, 0x7f, 0xff, 0xff, 0xff, 0xff, 0x6c, 0x5a, 0x32, 0x07, 0xf4, 0x75, 0x75, 0xf5,
    0x75, 0x75, 0x75, 0x7f, 0x5b, 0xd9, 0x32, 0x5a, 0x07, 0x19, 0x34, 0x2e, 0x2e, 0x2e,
    0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
    0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e, 0x2e,
    0xec, 0x9f, 0x69, 0x67, 0x7f, 0xff, 0xff, 0xff, 0xff, 0x6c, 0xfc, 0xf7, 0xfc, 0xfc,
    0xfc, 0xfc, 0xf4, 0x03, 0x03, 0x81, 0x81, 0x81, 0xfb, 0x7a, 0x30, 0x80, 0x3d, 0x59,
    0x59, 0x59, 0x59, 0x81, 0x00, 0x59, 0x2f, 0x45, 0x30, 0x32, 0xf4, 0x5d, 0x5b, 0x37,
    0x19,
  ]

  codeAddress = hexToByteArray[20]("000000000000000000000000636f6e7472616374")
  coinbase = hexToByteArray[20]("4444588443C3a91288c5002483449Aba1054192b")

proc runTestOverflow() =
  test "GasCall unhandled overflow":
    let header = BlockHeader(
      stateRoot: EMPTY_ROOT_HASH,
      number: 1150000'u64,
      coinBase: coinbase,
      gasLimit: 30000000,
      timeStamp: EthTime(123456),
    )

    let com = CommonRef.new(
      newCoreDbRef(DefaultDbMemory), config = chainConfigForNetwork(MainNet)
    )

    let s = BaseVMState.new(header, header, com)

    s.stateDB.setCode(codeAddress, @data)
    let unsignedTx = Transaction(
      txType: TxLegacy,
      nonce: 0,
      chainId: MainNet.ChainId,
      gasPrice: 0.GasInt,
      gasLimit: 30000000,
      to: Opt.some codeAddress,
      value: 0.u256,
      payload: @data,
    )

    let privateKey = PrivateKey.fromHex(
      "0000000000000000000000000000000000000000000000000000001000000000"
    )[]
    let tx = signTransaction(unsignedTx, privateKey, ChainId(1), false)
    let res = testCallEvm(tx, tx.getSender, s)

    when defined(evmc_enabled):
      check res.error == "EVMC_FAILURE"
    else:
      # After gasCall values always on positive, this test become OOG
      check res.error == "Opcode Dispatch Error: OutOfGas, depth=1"

proc evmSupportMain*() =
  runStackTests()
  runMemoryTests()
  runCodeStreamTests()
  runGasMeterTests()
  runMiscTests()
  runTestOverflow()

when isMainModule:
  evmSupportMain()
