# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  stint,
  stew/byteutils,
  eth/[common/eth_types, p2p]

{.push raises: [Defect].}

type
  InteriorPath* = object
    ## Path to an interior node in an Ethereum hexary trie.  This is a sequence
    ## of 0 to 64 hex digits.  0 digits means the root node, and 64 digits
    ## means a leaf node whose path hasn't been converted to `LeafPath` yet.
    bytes: array[32, byte]
    numDigits: byte

  LeafPath* = object
    ## Path to a leaf in an Ethereum hexary trie.  Individually, each leaf path
    ## is a hash, but rather than being the hash of the contents, it's the hash
    ## of the item's address.  Collectively, these hashes have some 256-bit
    ## numerical properties: ordering, intervals and meaningful difference.
    number: UInt256

  LeafRange* = object
    leafLow*, leafHigh*: LeafPath

const
   interiorPathMaxDepth = 64
   leafPathBytes = sizeof(LeafPath().number.toBytesBE)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc maxDepth*(_: InteriorPath | typedesc[InteriorPath]): int =
  interiorPathMaxDepth

proc depth*(path: InteriorPath): int =
  path.numDigits.int

proc digit*(path: InteriorPath, index: int): int =
  doAssert 0 <= index and index < path.depth
  let b = path.bytes[index shr 1]
  (if (index and 1) == 0: (b shr 4) else: (b and 0x0f)).int

proc low*(_: LeafPath | type LeafPath): LeafPath =
  LeafPath(number: low(UInt256))

proc high*(_: LeafPath | type LeafPath): LeafPath =
  LeafPath(number: high(UInt256))

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public `InteriorPath` functions
# ------------------------------------------------------------------------------

proc toInteriorPath*(interiorPath: InteriorPath): InteriorPath =
  interiorPath

proc toInteriorPath*(leafPath: LeafPath): InteriorPath =
  doAssert sizeof(leafPath.number.toBytesBE) * 2 == interiorPathMaxDepth
  doAssert sizeof(leafPath.number.toBytesBE) == sizeof(InteriorPath().bytes)
  InteriorPath(bytes: leafPath.number.toBytesBE,
               numDigits: interiorPathMaxDepth)

proc add*(path: var InteriorPath, digit: byte) =
  doAssert path.numDigits < interiorPathMaxDepth
  inc path.numDigits
  if (path.numDigits and 1) != 0:
    path.bytes[path.numDigits shr 1] = (digit shl 4)
  else:
    path.bytes[(path.numDigits shr 1) - 1] += (digit and 0x0f)

proc addPair*(path: var InteriorPath, digitPair: byte) =
  doAssert path.numDigits < interiorPathMaxDepth - 1
  path.numDigits += 2
  if (path.numDigits and 1) == 0:
    path.bytes[(path.numDigits shr 1) - 1] = digitPair
  else:
    path.bytes[(path.numDigits shr 1) - 1] += (digitPair shr 4)
    path.bytes[path.numDigits shr 1] = (digitPair shl 4)

proc pop*(path: var InteriorPath) =
  doAssert path.numDigits >= 1
  dec path.numDigits
  path.bytes[path.numDigits shr 1] =
    if (path.numDigits and 1) == 0: 0.byte
    else: path.bytes[path.numDigits shr 1] and 0xf0

# ------------------------------------------------------------------------------
# Public comparison functions for `InteriorPath`
# ------------------------------------------------------------------------------

proc `==`*(path1, path2: InteriorPath): bool =
  # Paths are zero-padded to the end of the array, so comparison is easy.
  for i in 0 ..< (max(path1.numDigits, path2.numDigits).int + 1) shr 1:
    if path1.bytes[i] != path2.bytes[i]:
      return false
  return true

proc `<=`*(path1, path2: InteriorPath): bool =
  # Paths are zero-padded to the end of the array, so comparison is easy.
  for i in 0 ..< (max(path1.numDigits, path2.numDigits).int + 1) shr 1:
    if path1.bytes[i] != path2.bytes[i]:
      return path1.bytes[i] <= path2.bytes[i]
  return true

proc cmp*(path1, path2: InteriorPath): int =
  # Paths are zero-padded to the end of the array, so comparison is easy.
  for i in 0 ..< (max(path1.numDigits, path2.numDigits).int + 1) shr 1:
    if path1.bytes[i] != path2.bytes[i]:
      return path1.bytes[i].int - path2.bytes[i].int
  return 0

proc `!=`*(path1, path2: InteriorPath): bool = not(path1 == path2)
proc `<`*(path1, path2: InteriorPath): bool = not(path2 <= path1)
proc `>=`*(path1, path2: InteriorPath): bool = path2 <= path1
proc `>`*(path1, path2: InteriorPath): bool = not(path1 <= path2)

# ------------------------------------------------------------------------------
# Public string output functions for `LeafPath`
# ------------------------------------------------------------------------------

proc toHex*(path: InteriorPath, withEllipsis = true): string =
  const hexChars = "0123456789abcdef"
  let digits = path.depth
  if not withEllipsis:
    result = newString(digits)
  else:
    result = newString(min(digits + 3, 64))
    result[^3] = '.'
    result[^2] = '.'
    result[^1] = '.'
  for i in 0 ..< digits:
    result[i] = hexChars[path.digit(i)]

proc pathRange*(path1, path2: InteriorPath): string =
  path1.toHex(false) & '-' & path2.toHex(false)

proc `$`*(path: InteriorPath): string =
  path.toHex

proc `$`*(paths: (InteriorPath, InteriorPath)): string =
  pathRange(paths[0], paths[1])

# ------------------------------------------------------------------------------
# Public `LeafPath` functions
# ------------------------------------------------------------------------------

proc toLeafPath*(leafPath: LeafPath): LeafPath =
  leafPath

proc toLeafPath*(interiorPath: InteriorPath): LeafPath =
  doAssert interiorPath.depth == InteriorPath.maxDepth
  doAssert sizeof(interiorPath.bytes) * 2 == InteriorPath.maxDepth
  doAssert sizeof(interiorPath.bytes) == leafPathBytes
  LeafPath(number: UInt256.fromBytesBE(interiorPath.bytes))

proc toLeafPath*(bytes: array[leafPathBytes, byte]): LeafPath =
  doAssert sizeof(bytes) == leafPathBytes
  LeafPath(number: UInt256.fromBytesBE(bytes))

proc toBytes*(leafPath: LeafPath): array[leafPathBytes, byte] =
  doAssert sizeof(LeafPath().number.toBytesBE) == leafPathBytes
  leafPath.number.toBytesBE

# Note, `{.borrow.}` didn't work for these symbols (with Nim 1.2.12) when we
# defined `LeafPath = distinct UInt256`.  The `==` didn't match any symbol to
# borrow from, and the auto-generated `<` failed to compile, with a peculiar
# type mismatch error.
proc `==`*(path1, path2: LeafPath): bool = path1.number == path2.number
proc `!=`*(path1, path2: LeafPath): bool = path1.number != path2.number
proc `<`*(path1, path2: LeafPath): bool = path1.number < path2.number
proc `<=`*(path1, path2: LeafPath): bool = path1.number <= path2.number
proc `>`*(path1, path2: LeafPath): bool = path1.number > path2.number
proc `>=`*(path1, path2: LeafPath): bool = path1.number >= path2.number
proc cmp*(path1, path2: LeafPath): int = cmp(path1.number, path2.number)

proc `-`*(path1, path2: LeafPath): UInt256 =
  path1.number - path2.number
proc `+`*(base: LeafPath, step: UInt256): LeafPath =
  LeafPath(number: base.number + step)
proc `+`*(base: LeafPath, step: SomeInteger): LeafPath =
  LeafPath(number: base.number + step.u256)
proc `-`*(base: LeafPath, step: UInt256): LeafPath =
  LeafPath(number: base.number - step)
proc `-`*(base: LeafPath, step: SomeInteger): LeafPath =
  LeafPath(number: base.number - step.u256)

# ------------------------------------------------------------------------------
# Public string output functions for `LeafPath`
# ------------------------------------------------------------------------------

proc toHex*(path: LeafPath): string =
  path.number.toBytesBE.toHex

proc `$`*(path: LeafPath): string =
  path.toHex

proc pathRange*(path1, path2: LeafPath): string =
  path1.toHex & '-' & path2.toHex

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
