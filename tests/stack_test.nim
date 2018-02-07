import unittest, macros, strformat, strutils, sequtils, constants, opcode_values, errors, vm / [stack, value], ttmath

suite "stack":
  test "push only valid":
    for value in @[0.vint, (pow(2.i256, 256) - 1.i256).vint, "ves".vbinary]:
      var stack = newStack()
      stack.push(value)
      check(stack.values == @[value])

    for value in @[(-1).vint, (-2).vint, "yzyzyzyzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz".vbinary]:
      var stack = newStack()
      expect(ValidationError):
        stack.push(value)

  test "push does not allow stack to exceed 1024":
    var stack = newStack()
    for z in 0 .. < 1024:
      stack.push(z)
    check(stack.len == 1024)
    expect(FullStack):
      stack.push(1025)

  test "dup does not allow stack to exceed 1024":
    var stack = newStack()
    stack.push(1.i256)
    for z in 0 ..< 1023:
      stack.dup(1.i256)
    check(stack.len == 1024)
    expect(FullStack):
      stack.dup(1.i256)
  
  test "pop returns latest stack item":
    var stack = newStack()
    for element in @[1.vint, 2.vint, 3.vint]:
      stack.push(element)
    check(stack.popInt == 3)

    stack = newStack()
    for element in @["1".vbinary]:
      stack.push(element)
    check(stack.popBinary == "1")


  test "swap correct":
    var stack = newStack()
    for z in 0 ..< 5:
      stack.push(z)
    check(stack.values == @[0.vint, 1.vint, 2.vint, 3.vint, 4.vint])
    stack.swap(3)
    check(stack.values == @[0.vint, 4.vint, 2.vint, 3.vint, 1.vint])
    stack.swap(1)
    check(stack.values == @[0.vint, 4.vint, 2.vint, 1.vint, 3.vint])

  test "dup correct":
    var stack = newStack()
    for z in 0 ..< 5:
      stack.push(z)
    check(stack.values == @[0.vint, 1.vint, 2.vint, 3.vint, 4.vint])
    stack.dup(1)
    check(stack.values == @[0.vint, 1.vint, 2.vint, 3.vint, 4.vint, 4.vint])
    stack.dup(5)
    check(stack.values == @[0.vint, 1.vint, 2.vint, 3.vint, 4.vint, 4.vint, 1.vint])

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
