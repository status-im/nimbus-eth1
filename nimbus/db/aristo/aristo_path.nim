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

proc pathAsBlob*(keyOrTag: NodeKey|Nodetag): Blob =
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
