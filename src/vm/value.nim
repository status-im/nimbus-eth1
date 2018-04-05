import
  strformat, strutils, sequtils,
  ../constants, ttmath

type
  ValueKind* = enum VInt, VBinary

  Value* = ref object
    case kind*: ValueKind:
    of VInt:
      Fi: array[32, byte] #Int256
    of VBinary:
      b*: seq[byte]

# TODO: The Int256 value is stored as array[32, byte], and we bitcast it
# back and forth. This is a hacky workaround for the problem that clang
# doesn't let you store ttmath types inside nim variant types (unions). Things
# should get better when we switch to mpint.

proc i*(v: Value): Int256 {.inline.} =
  cast[ptr Int256](unsafeAddr v.Fi)[]

proc `$`*(value: Value): string =
  case value.kind:
  of VInt:
    &"Int({value.i})"
  of VBinary:
    &"Binary({value.b})"

proc toArr(i: Int256): array[32, byte] {.inline.} =
  cast[ptr array[32, byte]](unsafeAddr i)[]

proc vint*(i: Int256): Value =
  Value(kind: VInt, Fi: i.toArr)

proc vint*(i: int): Value {.inline.} = vint(i.int256)

proc vbinary*(b: string): Value =
  Value(kind: VBinary, b: b.mapIt(it.byte))

proc vbinary*(b: seq[byte]): Value =
  Value(kind: VBinary, b: b)
