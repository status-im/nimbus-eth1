import
  strformat, macros,
  ../constants, ../errors, ../computation, .. / vm / [stack, code_stream], .. / utils / [padding, bytes], bigints

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc pop*(computation) =
  discard stack.pop()

macro pushXX(size: static[int]): untyped =
  let computation = ident("computation")
  let value = ident("value")
  let name = ident(&"push{size}")
  result = quote:
    proc `name`*(`computation`: var BaseComputation) =
      let `value` = `computation`.code.read(`size`).toCString
      let stripped = `value`.strip(0.char)
      if stripped.len == 0:
        `computation`.stack.push(0.i256)
      else:
        let paddedValue = `value`.padRight(`size`, cstring"\x00")
        `computation`.stack.push(paddedValue)


pushXX(1)
pushXX(2)
pushXX(3)
pushXX(4)
pushXX(5)
pushXX(6)
pushXX(7)
pushXX(8)
pushXX(9)
pushXX(10)
pushXX(11)
pushXX(12)
pushXX(13)
pushXX(14)
pushXX(15)
pushXX(16)
pushXX(17)
pushXX(18)
pushXX(19)
pushXX(20)
pushXX(21)
pushXX(22)
pushXX(23)
pushXX(24)
pushXX(25)
pushXX(26)
pushXX(27)
pushXX(28)
pushXX(29)
pushXX(30)
pushXX(31)
pushXX(32)
