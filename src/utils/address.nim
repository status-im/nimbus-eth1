import strformat, strutils, encodings

proc toText(c: cstring): string =
  ($c).convert(destEncoding="iso-8859-1")

proc toCanonicalAddress*(address: string): string =
  # TODO
  address
  # address.toNormalizedAddress.decodeHex

proc toCanonicalAddress*(address: cstring): string =
  address.toText.toCanonicalAddress

# proc isNormalizedAddress*(value: string): bool =
#   # Returns whether the provided value is an address in it's normalized form
#   if not value.isAddress:
#     false
#   else:
#     value == value.toNormalizedAddress

# proc toNormalizedAddress*(address: string): string =
#   # Converts an address to it's normalized hexidecimal representation
#   if address.isHexAddress:
#     address.normalizeHexAddress
#   elif address.isBinaryAddress:
#     address.normalizeBinaryAddress
#   elif address.is32byteaddress:
#     address.normalize32byteAddress
#   else:
#     raise newException(ValueError, &"Unknown address format {address}")

# proc toNormalizedAddress*(address: cstring): string =
#   toNormalizedAddress(address.toText)

# proc isAddress*(value: string): bool
#   # Checks if the given string is an address in any of the known formats
#   if value.isChecksumFormattedAddress:
#     value.isChecksumAddress
#   elif value.isHexAddress:
#     true
#   elif value.isBinaryAddress:
#     true
#   elif value.is32byteAddress:
#     true
#   else:
#     false

# proc toCanonicalAddress*(address: cstring): string =
#   address.toText.toNormalizedAddress.decodeHex

# proc toCanonicalAddress*(address: string): string =
#   address.toNormalizedAddress.decodeHex

# proc isHexAddress(value: string): cstring =
#   # Checks if the given string is an address in hexidecimal encoded form
#   if value.len notin {42, 40}:
#     false
#   else:
#     value.isHex:

# proc isBinaryAddress(value: string): bool =
#   # Checks if the given string is an address in raw bytes form
#   value.len == 20

# proc is32byteAddress(value: string): bool =
#   # Checks if the given string is an address in hexidecimal encoded form padded to 32 bytes
#   let valueAsHex = ""
#   if value.len == 32:
#     valueAsHex = value.encodeHex
#   elif value.len in {66, 64}:
#     valueAsHex = value.add0xprefix
#   else:
#     return false

#   if valueAsHex.isPrefixed("0x000000000000000000000000"):
#     try:
#       return valueAsHex.parseHexInt > 0
#     except ValueError:
#       false
#   else:
#     return false

# proc normalizeHexAddress(address: string): string =
#   # Returns a hexidecimal address in its normalized hexidecimal representation
#   address.toLowerAscii.add0xPrefix

# proc normalizeBinaryAddress(address: string): string =
#   # Returns a raw binary address in its normalized hexidecimal representation
#   address.encodeHex.normalizeHexAddress

# proc normalize32byteAddress(address: string): string =
#   if address.len == 32:
#     address[^20..^1].normalizeBinaryAddress
#   elif address.len in {66, 64}:
#     address[^40..^1].normalizeHexAddress
#   else:
#     raise newException(ValueError, "Invalid address(must be 32 byte value)")

# proc isCanonicalAddress(value: string): bool =
#   if not value.isAddress
#     false
#   else:
#     value == value.toCanonicalAddress

# proc isSameAddress(left: string, right: string): bool =
#   # Checks if both addresses are same or not
#   if not left.isAddress or not right.isAddress:
#     raise newException(ValueError, "Both values must be valid addresses")
#   else:
#     left.toNormalizedAddress == right.toNormalizedAddress

# proc toChecksumAddress*(address: string): string =
#   # Makes a checksum address
#   let normAddress = address.toNormalizedAddress
#   let addressHash = normAddress.remove0xPrefix.keccak.encodeHex
#   var s = ""
#   for z in 2 ..< 42:
#     s.add(if addressHash[z].parseHexInt > 7: normAddress[z].toUpperAscii() else: normAddress[z])

#   result = s.join("").add0xPrefix

# proc toChecksumAddress*(address: cstring): string =
#   address.toText.toChecksumAddress

# proc isChecksumAddress(value: string): bool =
#   if not value.isHexAddress:
#     false
#   else:
#     value == value.toChecksumAddress

# proc isChecksumFormattedAddress*(value: string): bool =
#   if not value.isHexAddress:
#     false
#   else:
#     let r = value.remove0xPrefix
#     r != r.toLowerAscii and r != r.toUpperAscii
