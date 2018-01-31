import strutils, sequtils

# proc toBytes*(value: cstring): seq[byte] =
#   result = newSeq[byte](value.len)
#   for z, c in value:
#     result[z] = c.byte
#   # result = toSeq(value)

# proc toCString*(value: seq[byte]): cstring =
#   var res = ""
#   for c in value:
#     res.add(c.char)
#   cstring(res) # TODO: faster

proc toString*(value: seq[byte]): string =
  value.mapIt(it.char).join("")

proc toBytes*(value: string): seq[byte] =
  result = value.mapIt(it.byte)
