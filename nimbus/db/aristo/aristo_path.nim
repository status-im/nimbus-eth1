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
  stew/results,
  "."/[aristo_constants, aristo_desc, aristo_error]

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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pathAsNibbles*(key: NodeKey): NibblesSeq =
  key.ByteArray32.initNibbleRange()

proc pathAsNibbles*(tag: NodeTag): NibblesSeq =
  tag.to(NodeKey).pathAsNibbles()

proc pathAsBlob*(keyOrTag: NodeKey|NodeTag): Blob =
  keyOrTag.pathAsNibbles.hexPrefixEncode(isLeaf=true)


proc pathToKey*(partPath: NibblesSeq): Result[NodeKey,AristoError] =
  var key: ByteArray32
  if partPath.len == 64:
    # Trailing dummy nibbles (aka no nibbles) force a nibble seq reorg
    let path = (partPath & EmptyNibbleSeq).getBytes()
    (addr key[0]).copyMem(unsafeAddr path[0], 32)
    return ok(key.NodeKey)
  err(PathExpected64Nibbles)

proc pathToKey*(partPath: Blob): Result[NodeKey,AristoError] =
  let (isLeaf,pathSegment) = partPath.hexPrefixDecode
  if isleaf:
    return pathSegment.pathToKey()
  err(PathExpectedLeaf)

proc pathToTag*(partPath: NibblesSeq|Blob): Result[NodeTag,AristoError] =
  let rc = partPath.pathToKey()
  if rc.isOk:
    return ok(rc.value.to(NodeTag))
  err(rc.error)

# --------------------

proc pathPfxPad*(pfx: NibblesSeq; dblNibble: static[byte]): NibblesSeq =
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

proc pathPfxPadKey*(pfx: NibblesSeq; dblNibble: static[byte]): NodeKey =
  ## Variant of `pathPfxPad()`.
  ##
  ## Extend (or cut) the argument nibbles sequence `pfx` for generating a
  ## `NodeKey`.
  let bytes = pfx.pathPfxPad(dblNibble).getBytes
  (addr result.ByteArray32[0]).copyMem(unsafeAddr bytes[0], bytes.len)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
