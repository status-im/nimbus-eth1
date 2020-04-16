# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2,
  eth/common/eth_types,
  ../nimbus/[constants, errors, vm/interpreter]


template testPush(value: untyped, expected: untyped): untyped =
  var stack = newStack()
  stack.push(value)
  check(stack.values == @[expected])

template testFailPush(value: untyped): untyped {.used.} =
  var stack = newStack()
  expect(ValidationError):
    stack.push(value)

func toBytes(s: string): seq[byte] =
  cast[seq[byte]](s)

func bigEndianToInt*(value: openarray[byte]): UInt256 =
  result.initFromBytesBE(value)

proc stackMain*() =
  suite "stack":
    test "push only valid":
      testPush(0'u, 0.u256)
      testPush(UINT_256_MAX, UINT_256_MAX)
      testPush("ves".toBytes, "ves".toBytes.bigEndianToInt)

      # Appveyor mysterious failure.
      # Raising exception in this file will force the
      # program to quit because of SIGSEGV.
      # Cannot reproduce locally, and doesn't happen
      # in other file.
      when not(defined(windows) and
        defined(cpu64) and
        (NimMajor, NimMinor, NimPatch) >= (1, 0, 4)):
        testFailPush("yzyzyzyzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz".toBytes)

    test "push does not allow stack to exceed 1024":
      var stack = newStack()
      for z in 0 ..< 1024:
        stack.push(z.uint)
      check(stack.len == 1024)
      expect(FullStack):
        stack.push(1025)

    test "dup does not allow stack to exceed 1024":
      var stack = newStack()
      stack.push(1.u256)
      for z in 0 ..< 1023:
        stack.dup(1)
      check(stack.len == 1024)
      expect(FullStack):
        stack.dup(1)

    test "pop returns latest stack item":
      var stack = newStack()
      for element in @[1'u, 2'u, 3'u]:
        stack.push(element)
      check(stack.popInt == 3.u256)

    test "swap correct":
      var stack = newStack()
      for z in 0 ..< 5:
        stack.push(z.uint)
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256])
      stack.swap(3)
      check(stack.values == @[0.u256, 4.u256, 2.u256, 3.u256, 1.u256])
      stack.swap(1)
      check(stack.values == @[0.u256, 4.u256, 2.u256, 1.u256, 3.u256])

    test "dup correct":
      var stack = newStack()
      for z in 0 ..< 5:
        stack.push(z.uint)
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256])
      stack.dup(1)
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256, 4.u256])
      stack.dup(5)
      check(stack.values == @[0.u256, 1.u256, 2.u256, 3.u256, 4.u256, 4.u256, 1.u256])

    test "pop raises InsufficientStack appropriately":
      var stack = newStack()
      expect(InsufficientStack):
        discard stack.popInt()

    test "swap raises InsufficientStack appropriately":
      var stack = newStack()
      expect(InsufficientStack):
        stack.swap(0)

    test "dup raises InsufficientStack appropriately":
      var stack = newStack()
      expect(InsufficientStack):
        stack.dup(0)

    test "binary operations raises InsufficientStack appropriately":
      # https://github.com/status-im/nimbus/issues/31
      # ./tests/fixtures/VMTests/vmArithmeticTest/mulUnderFlow.json

      var stack = newStack()
      stack.push(123)
      expect(InsufficientStack):
        discard stack.popInt(2)
