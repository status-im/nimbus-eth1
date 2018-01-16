import ../constants

type
  ValueKind* = enum VInt, VBinary

  Value* = ref object
    case kind*: ValueKind:
    of VInt:
      i*: Int256
    of VBinary:
      b*: cstring

