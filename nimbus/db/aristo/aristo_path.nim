# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  eth/[common, trie/nibbles],
  results,
  ./aristo_desc

# Info snippet (just a reminder to keep somewhere)
#
# Extension of a compact encoded as prefixed sequence of nibbles (i.e.
# half bytes with 4 bits.)
#
#   pfx | bits | vertex type | layout
#   ----+ -----+-------------+----------------------------------------
#    0  | 0000 | extension   | @[<pfx, ignored>,      nibble-pair, ..]
#    1  | 0001 | extension   | @[<pfx, first-nibble>, nibble-pair, ..]
#    2  | 0010 | leaf        | @[<pfx, ignored>,      nibble-pair, ..]
#    3  | 0011 | leaf        | @[<pfx, first-nibble>, nibble-pair, ..]
#
# where the `ignored` part is typically expected a zero nibble.

func pathPfxPad*(pfx: NibblesSeq; dblNibble: static[byte]): NibblesSeq

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func pathAsBlob*(tag: PathID): Blob =
  ## Convert the `tag` argument to a sequence of an even number of nibbles
  ## represented by a `Blob`. If the argument `tag` represents an odd number
  ## of nibbles, a zero nibble is appendend.
  ##
  ## This function is useful only if there is a tacit agreement that all paths
  ## used to index database leaf values can be represented as `Blob`, i.e.
  ## `PathID` type paths with an even number of nibbles.
  if 0 < tag.length:
    let key = @(tag.pfx.toBytesBE)
    if 64 <= tag.length:
      return key
    else:
      return key[0 .. (tag.length + 1) div 2]

func pathAsHEP*(tag: PathID; isLeaf = false): Blob =
  ## Convert the `tag` argument to a hex encoded partial path as used in `eth`
  ## or `snap` protocol where full paths of nibble length 64 are encoded as 32
  ## byte `Blob` and non-leaf partial paths are *compact encoded* (i.e. per
  ## the Ethereum wire protocol.)
  if 64 <= tag.length:
    @(tag.pfx.toBytesBE)
  else:
    tag.to(NibblesSeq).hexPrefixEncode(isLeaf=true)

func pathToTag*(partPath: NibblesSeq): Result[PathID,AristoError] =
  ## Convert the argument `partPath`  to a `PathID` type value.
  if partPath.len == 0:
    return ok VOID_PATH_ID
  if partPath.len <= 64:
    return ok PathID(
      pfx:    UInt256.fromBytesBE partPath.pathPfxPad(0).getBytes(),
      length: partPath.len.uint8)
  err(PathAtMost64Nibbles)

func pathToTag*(partPath: openArray[byte]): Result[PathID,AristoError] =
  ## Variant of `pathToTag()`
  if partPath.len == 0:
    return ok VOID_PATH_ID
  if partPath.len <= 32:
    return ok PathID(
      pfx:    UInt256.fromBytesBE @partPath & 0u8.repeat(32-partPath.len),
      length: 2 * partPath.len.uint8)
  err(PathAtMost64Nibbles)

# --------------------

func pathPfxPad*(pfx: NibblesSeq; dblNibble: static[byte]): NibblesSeq =
  ## Extend (or cut) the argument nibbles sequence `pfx` for generating a
  ## `NibblesSeq` with exactly 64 nibbles, the equivalent of a path key.
  ##
  ## This function must be handled with some care regarding a meaningful value
  ## for the `dblNibble` argument. Currently, only static values `0` and `255`
  ## are allowed for padding. This is checked at compile time.
  static:
    doAssert dblNibble == 0 or dblNibble == 255

  let padLen = 64 - pfx.len
  if 0 <= padLen:
    result = pfx & dblNibble.repeat(padLen div 2).mapIt(it.byte).initNibbleRange
    if (padLen and 1) == 1:
      result = result & @[dblNibble.byte].initNibbleRange.slice(1)
  else:
    let nope = seq[byte].default.initNibbleRange
    result = pfx.slice(0,64) & nope # nope forces re-alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
