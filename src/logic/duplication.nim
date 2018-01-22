import
  macros, strformat,
  ../computation, ../vm/stack

macro dupXX(position: static[int]): untyped =
  let name = ident(&"dup{position}")
  result = quote:
    proc `name`*(computation: var BaseComputation) =
      computation.stack.dup(`position`)

dupXX(1)
dupXX(2)
dupXX(3)
dupXX(4)
dupXX(5)
dupXX(6)
dupXX(7)
dupXX(8)
dupXX(9)
dupXX(10)
dupXX(11)
dupXX(12)
dupXX(13)
dupXX(14)
dupXX(15)
dupXX(16)

