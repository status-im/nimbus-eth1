import
  strformat, strutils,
  ../constants, bigints

type
  ValueKind* = enum VInt, VBinary

  Value* = ref object
    case kind*: ValueKind:
    of VInt:
      i*: Int256
    of VBinary:
      b*: string

proc `$`*(value: Value): string =
  case value.kind:
  of VInt:
    &"Int({value.i})"
  of VBinary:
    &"Binary({value.b})"

proc vint*(i: int): Value =
  Value(kind: VInt, i: i.int256)

proc vint*(i: Int256): Value =
  Value(kind: VInt, i: i)

proc vbinary*(b: string): Value =
  Value(kind: VBinary, b: b)

