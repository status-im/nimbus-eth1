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
  eth/common/eth_types,
  stew/byteutils,
  stint,
  ../../utils/interval_set

{.push raises: [Defect].}

type
  LeafItem* =
    distinct UInt256

  LeafRange* = ##\
    ## Interval `[minPt,maxPt]` of` LeafItem` elements, can be managed in an
    ## `IntervalSet` data type.
    Interval[LeafItem,UInt256]

  LeafItemData* = ##\
    ## Serialisation of `LeafItem`
    array[32,byte]

  InteriorPath* = object
    ## Path to an interior node in an Ethereum hexary trie.  This is a sequence
    ## of 0 to 64 hex digits.  0 digits means the root node, and 64 hex digits
    ## means a leaf node whose path hasn't been converted to `LeafItem` yet.
    bytes: LeafItemData
    numDigits: byte

const
   interiorPathMaxDepth = 2 * sizeof(LeafItemData)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc to*(lp: LeafItem; T: type LeafItemData): T =
  lp.UInt256.toBytesBE.T

proc to*(data: LeafItemData; T: type LeafItem): T =
  UInt256.fromBytesBE(data).T

proc to*(ip: InteriorPath; T: type LeafItem): T =
  ip.bytes.to(T)

proc to*(hash: UInt256; T: type LeafItem): T =
  hash.T

proc to*(lp: LeafItem; T: type InteriorPath): T =
  InteriorPath(bytes: lp.to(LeafItemData), numDigits: interiorPathMaxDepth)

# ------------------------------------------------------------------------------
# Public `InteriorPath` functions
# ------------------------------------------------------------------------------

proc maxDepth*(_: InteriorPath | typedesc[InteriorPath]): int =
  interiorPathMaxDepth

proc depth*(ip: InteriorPath): int =
  ip.numDigits.int

proc digit*(ip: InteriorPath, index: int): int =
  doAssert 0 <= index and index < ip.depth
  let b = ip.bytes[index shr 1]
  (if (index and 1) == 0: (b shr 4) else: (b and 0x0f)).int

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
  doAssert 0 < path.numDigits
  dec path.numDigits
  path.bytes[path.numDigits shr 1] =
    if (path.numDigits and 1) == 0: 0.byte
    else: path.bytes[path.numDigits shr 1] and 0xf0

# ------------------------------------------------------------------------------
# Public comparison functions for `InteriorPath`
# ------------------------------------------------------------------------------

proc low*(T: type InteriorPath): T = low(UInt256).to(LeafItem).to(T)
proc high*(T: type InteriorPath): T = high(UInt256).to(LeafItem).to(T)

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

proc `<`*(path1, path2: InteriorPath): bool = not(path2 <= path1)

#proc cmp*(path1, path2: InteriorPath): int =
#  # Paths are zero-padded to the end of the array, so comparison is easy.
#  for i in 0 ..< (max(path1.numDigits, path2.numDigits).int + 1) shr 1:
#    if path1.bytes[i] != path2.bytes[i]:
#      return path1.bytes[i].int - path2.bytes[i].int
#  return 0

proc prefix*(lp: LeafItem; digits: byte): InteriorPath =
  ## From the argument item `lp`, return the prefix made up by preserving the
  ## leading `digit` nibbles (ie. `(digits+1)/2` bytes.)
  doAssert digits <= interiorPathMaxDepth
  result = InteriorPath(
    bytes:     lp.to(LeafItemData),
    numDigits: digits)
  let tailInx = (digits + 1) shr 1
  # reset the tail to zero
  for inx in tailInx ..< interiorPathMaxDepth:
    result.bytes[inx] = 0.byte
  if (digits and 1) != 0: # fix leftlost nibble
    result.bytes[digits shr 1] = result.bytes[digits shr 1] and 0xf0.byte

proc `in`*(ip: InteriorPath; iv: LeafRange): bool =
  iv.minPt.prefix(ip.numDigits) <= ip and ip <= iv.maxPt.prefix(ip.numDigits)


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
  path1.toHex(withEllipsis = false) & '-' & path2.toHex(withEllipsis = false)

proc `$`*(path: InteriorPath): string =
  path.toHex

proc `$`*(paths: (InteriorPath, InteriorPath)): string =
  pathRange(paths[0], paths[1])

# ------------------------------------------------------------------------------
# Public `LeafItem` and `LeafRange` functions
# ------------------------------------------------------------------------------

proc u256*(lp: LeafItem): UInt256 = lp.UInt256
proc low*(T: type LeafItem): T = low(UInt256).T
proc high*(T: type LeafItem): T = high(UInt256).T

proc `+`*(a: LeafItem; b: UInt256): LeafItem = (a.u256+b).LeafItem
proc `-`*(a: LeafItem; b: UInt256): LeafItem = (a.u256-b).LeafItem
proc `-`*(a, b: LeafItem): UInt256 = (a.u256 - b.u256)

proc `==`*(a, b: LeafItem): bool = a.u256 == b.u256
proc `<=`*(a, b: LeafItem): bool = a.u256 <= b.u256
proc `<`*(a, b: LeafItem): bool = a.u256 < b.u256


# RLP serialisation for `LeafItem`.
proc read*(rlp: var Rlp, T: type LeafItem): T
    {.gcsafe, raises: [Defect,RlpError]} =
  rlp.read(LeafItemData).to(T)

proc append*(rlpWriter: var RlpWriter, leafPath: LeafItem) =
  rlpWriter.append(leafPath.to(LeafItemData))


# Printing & pretty printing
proc toHex*(lp: LeafItem): string = lp.to(LeafItemData).toHex
proc `$`*(lp: LeafItem): string = lp.toHex

proc leafRangePp*(a, b: LeafItem): string =
  ## Needed for macro generated DSL files like `snap.nim` because the
  ## `distinct` flavour of `LeafItem` is discarded there.
  result = "[" & $a
  if a < b:
    result &= ',' & (if b < high(LeafItem): $b else: "high")
  result &= "]"

proc `$`*(a, b: LeafItem): string =
  ## Prettyfied prototype
  leafRangePp(a,b)

proc `$`*(iv: LeafRange): string =
  leafRangePp(iv.minPt, iv.maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
