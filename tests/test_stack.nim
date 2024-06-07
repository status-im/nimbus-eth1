# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/importutils,
  unittest2,
  eth/common/eth_types,
  ../nimbus/evm/evm_errors,
  ../nimbus/evm/stack,
  ../nimbus/constants

template testPush(value: untyped, expected: untyped): untyped =
  privateAccess(EvmStackRef)
  var stack = EvmStackRef.new()
  check stack.push(value).isOk
  check(stack.values == @[expected])

func toBytes(s: string): seq[byte] =
  cast[seq[byte]](s)

func bigEndianToInt*(value: openArray[byte]): UInt256 =
  result.initFromBytesBE(value)

proc stackMain*() =
  suite "stack":
    test "push only valid":
      testPush(0'u, 0.u256)
      testPush(UINT_256_MAX, UINT_256_MAX)
      testPush("ves".toBytes, "ves".toBytes.bigEndianToInt)

    test "push does not allow stack to exceed 1024":
      var stack = EvmStackRef.new()
      for z in 0 ..< 1024:
        check stack.push(z.uint).isOk
      check(stack.len == 1024)
      check stack.push(1025).error.code == EvmErrorCode.StackFull

    test "dup does not allow stack to exceed 1024":
      var stack = EvmStackRef.new()
      check stack.push(1.u256).isOk
      for z in 0 ..< 1023:
        check stack.dup(1).isOk
      check(stack.len == 1024)
      check stack.dup(1).error.code == EvmErrorCode.StackFull

    test "pop returns latest stack item":
      var stack = EvmStackRef.new()
      for element in @[1'u, 2'u, 3'u]:
        check stack.push(element).isOk
      check(stack.popInt.get == 3.u256)

    test "swap correct":
      privateAccess(EvmStackRef)
      var stack = EvmStackRef.new()
      for z in 0 ..< 5:
        check stack.push(z.uint).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256])
      check stack.swap(3).isOk
      check(stack.values == @[0.u256, 4.u256, 2.u256, 3.u256, 1.u256])
      check stack.swap(1).isOk
      check(stack.values == @[0.u256, 4.u256, 2.u256, 1.u256, 3.u256])

    test "dup correct":
      privateAccess(EvmStackRef)
      var stack = EvmStackRef.new()
      for z in 0 ..< 5:
        check stack.push(z.uint).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256])
      check stack.dup(1).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256, 4.u256])
      check stack.dup(5).isOk
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256, 4.u256, 1.u256])

    test "pop raises InsufficientStack appropriately":
      var stack = EvmStackRef.new()
      check stack.popInt().error.code == EvmErrorCode.StackInsufficient

    test "swap raises InsufficientStack appropriately":
      var stack = EvmStackRef.new()
      check stack.swap(0).error.code == EvmErrorCode.StackInsufficient

    test "dup raises InsufficientStack appropriately":
      var stack = EvmStackRef.new()
      check stack.dup(0).error.code == EvmErrorCode.StackInsufficient

    test "binary operations raises InsufficientStack appropriately":
      # https://github.com/status-im/nimbus/issues/31
      # ./tests/fixtures/VMTests/vmArithmeticTest/mulUnderFlow.json

      var stack = EvmStackRef.new()
      check stack.push(123).isOk
      check stack.popInt(2).error.code == EvmErrorCode.StackInsufficient

when isMainModule:
  stackMain()
