import strutils

proc encodeHex*(value: string): string =
  # return "0x" & codecs.decode(codecs.encode(value, "hex"), "utf8")
  return value

proc decodeHex*(value: string): string =
  # var hexPart = value.rsplit("x", 1)[1]
  return value
  # return codecs.decode(hexPart, "hex")

