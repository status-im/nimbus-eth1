type
  ValueKind* = enum VInt, VBinary

  Value* = ref object
    case kind*: ValueKind:
    of VInt:
      i*: int
    of VBinary:
      b*: cstring

