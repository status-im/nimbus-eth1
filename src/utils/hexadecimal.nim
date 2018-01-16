import strutils

proc encodeHex*(value: cstring): string =
  # return "0x" & codecs.decode(codecs.encode(value, "hex"), "utf8")
  return $value

proc decodeHex*(value: string): cstring =
  # var hexPart = value.rsplit("x", 1)[1]
  return cstring(value)
  # return codecs.decode(hexPart, "hex")

