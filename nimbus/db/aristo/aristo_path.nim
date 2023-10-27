# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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

func pathAsBlob*(keyOrTag: HashKey|PathID): Blob =
  keyOrTag.to(NibblesSeq).hexPrefixEncode(isLeaf=true)

func pathToKey*(partPath: NibblesSeq): Result[HashKey,AristoError] =
  var key: ByteArray32
  if partPath.len == 64:
    # Trailing dummy nibbles (aka no nibbles) force a nibble seq reorg
    let path = (partPath & EmptyNibbleSeq).getBytes()
    (addr key[0]).copyMem(unsafeAddr path[0], 32)
    return ok(key.HashKey)
  err(PathExpected64Nibbles)

func pathToKey*(
    partPath: openArray[byte];
      ): Result[HashKey,AristoError] =
  let (isLeaf,pathSegment) = partPath.hexPrefixDecode
  if isleaf:
    return pathSegment.pathToKey()
  err(PathExpectedLeaf)

func pathToTag*(partPath: NibblesSeq): Result[PathID,AristoError] =
  ## Nickname `tag` for `PathID`
  if partPath.len <= 64:
    return ok PathID(
      pfx:    UInt256.fromBytesBE partPath.pathPfxPad(0).getBytes(),
      length: partPath.len.uint8)
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
    result = pfx & dblNibble.repeat(padlen div 2).mapIt(it.byte).initNibbleRange
    if (padLen and 1) == 1:
      result = result & @[dblNibble.byte].initNibbleRange.slice(1)
  else:
    let nope = seq[byte].default.initNibbleRange
    result = pfx.slice(0,64) & nope # nope forces re-alignment

func pathPfxPadKey*(pfx: NibblesSeq; dblNibble: static[byte]): HashKey =
  ## Variant of `pathPfxPad()`.
  ##
  ## Extend (or cut) the argument nibbles sequence `pfx` for generating a
  ## `HashKey`.
  let bytes = pfx.pathPfxPad(dblNibble).getBytes
  (addr result.ByteArray32[0]).copyMem(unsafeAddr bytes[0], bytes.len)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
