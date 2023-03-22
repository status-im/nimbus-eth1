# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Helpers to treat persistent and in-memory database in a similar way

{.push raises: [].}

import
  std/[sequtils, tables],
  eth/[common, trie/nibbles],
  stew/results,
  ../../range_desc,
  "."/[hexary_desc, hexary_error]

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc isZeroLink*(a: Blob): bool =
  ## Persistent database has `Blob` as key
  a.len == 0

proc isZeroLink*(a: RepairKey): bool =
  ## Persistent database has `RepairKey` as key
  a.isZero

proc `==`*(a, b: XNodeObj): bool =
  if a.kind == b.kind:
    case a.kind:
    of Leaf:
      return a.lPfx == b.lPfx and a.lData == b.lData
    of Extension:
      return a.ePfx == b.ePfx and a.eLink == b.eLink
    of Branch:
      return a.bLink == b.bLink

# ------------------

proc toBranchNode*(
    rlp: Rlp
      ): XNodeObj
      {.gcsafe, raises: [RlpError]} =
  var rlp = rlp
  XNodeObj(kind: Branch, bLink: rlp.read(array[17,Blob]))

proc toLeafNode*(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [RlpError]} =
  XNodeObj(kind: Leaf, lPfx: pSegm, lData: rlp.listElem(1).toBytes)

proc toExtensionNode*(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [RlpError]} =
  XNodeObj(kind: Extension, ePfx: pSegm, eLink: rlp.listElem(1).toBytes)

# ------------------

proc getNode*(
    nodeKey: RepairKey;            # Node key
    db: HexaryTreeDbRef;           # Database
      ): Result[RNodeRef,HexaryError]
      {.gcsafe, raises: [KeyError].} =
  ## Fetch root node for given path
  if db.tab.hasKey(nodeKey):
    return ok(db.tab[nodeKey])
  err(NearbyDanglingLink)

proc getNode*(
    nodeKey: openArray[byte];      # Node key
    getFn: HexaryGetFn;            # Database abstraction
      ): Result[XNodeObj,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `getRootNode()`
  let nodeData = nodeKey.getFn
  if 0 < nodeData.len:
    let nodeRlp = rlpFromBytes nodeData
    case nodeRlp.listLen:
    of 17:
      return ok(nodeRlp.toBranchNode)
    of 2:
      let (isLeaf,pfx) = hexPrefixDecode nodeRlp.listElem(0).toBytes
      if isleaf:
        return ok(nodeRlp.toLeafNode pfx)
      else:
        return ok(nodeRlp.toExtensionNode pfx)
    else:
      return err(NearbyGarbledNode)
  err(NearbyDanglingLink)

proc getNode*(
    nodeKey: NodeKey;              # Node key
    getFn: HexaryGetFn;            # Database abstraction
      ): Result[XNodeObj,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `getRootNode()`
  nodeKey.ByteArray32.getNode(getFn)

# ------------------

proc padPartialPath*(pfx: NibblesSeq; dblNibble: byte): NodeKey =
  ## Extend (or cut) `partialPath` nibbles sequence and generate `NodeKey`.
  ## This function must be handled with some care regarding a meaningful value
  ## for the `dblNibble` argument. Using values `0` or `255` is typically used
  ## to create the minimum or maximum envelope value from the `pfx` argument.
  # Pad with zeroes
  var padded: NibblesSeq

  let padLen = 64 - pfx.len
  if 0 <= padLen:
    padded = pfx & dblNibble.repeat(padlen div 2).initNibbleRange
    if (padLen and 1) == 1:
      padded = padded & @[dblNibble].initNibbleRange.slice(1)
  else:
    let nope = seq[byte].default.initNibbleRange
    padded = pfx.slice(0,64) & nope # nope forces re-alignment

  let bytes = padded.getBytes
  (addr result.ByteArray32[0]).copyMem(unsafeAddr bytes[0], bytes.len)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
