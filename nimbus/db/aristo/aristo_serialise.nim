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
  eth/[common, rlp, trie/nibbles],
  results,
  "."/[aristo_constants, aristo_desc, aristo_get]

# Annotation helper
{.pragma: noRaise, gcsafe, raises: [].}

type
  ResolveVidFn = proc(vid: VertexID): Result[HashKey,AristoError] {.noRaise.}
    ## Resolve storage root vertex ID

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc aristoError(error: AristoError): NodeRef =
  ## Allows returning de
  NodeRef(vType: Leaf, error: error)

proc serialise(
    pyl: PayloadRef;
    getKey: ResolveVidFn;
      ): Result[Blob,(VertexID,AristoError)] =
  ## Encode the data payload of the argument `pyl` as RLP `Blob` if it is of
  ## account type, otherwise pass the data as is.
  ##
  case pyl.pType:
  of RawData:
    ok pyl.rawBlob
  of AccountData:
    let
      vid = pyl.account.storageID
      key = block:
        if vid.isValid:
          vid.getKey.valueOr:
            let w = (vid,error)
            return err(w)
        else:
          VOID_HASH_KEY

    ok rlp.encode Account(
      nonce:       pyl.account.nonce,
      balance:     pyl.account.balance,
      storageRoot: key.to(Hash256),
      codeHash:    pyl.account.codeHash)

# ------------------------------------------------------------------------------
# Public RLP transcoder mixins
# ------------------------------------------------------------------------------

proc read*(rlp: var Rlp; T: type NodeRef): T {.gcsafe, raises: [RlpError].} =
  ## Mixin for RLP writer, see `fromRlpRecord()` for an encoder with detailed
  ## error return code (if needed.) This reader is a jazzed up version which
  ## reports some particular errors in the `Dummy` type node.
  if not rlp.isList:
    # Otherwise `rlp.items` would raise a `Defect`
    return aristoError(Rlp2Or17ListEntries)

  var
    blobs = newSeq[Blob](2)         # temporary, cache
    links: array[16,HashKey]        # reconstruct branch node
    top = 0                         # count entries and positions

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    case top
    of 0, 1:
      if not w.isBlob:
        return aristoError(RlpBlobExpected)
      blobs[top] = rlp.read(Blob)
    of 2 .. 15:
      let blob = rlp.read(Blob)
      links[top] = HashKey.fromBytes(blob).valueOr:
        return aristoError(RlpBranchHashKeyExpected)
    of 16:
      if not w.isBlob or 0 < rlp.read(Blob).len:
        return aristoError(RlpEmptyBlobExpected)
    else:
      return aristoError(Rlp2Or17ListEntries)
    top.inc

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return aristoError(RlpNonEmptyBlobExpected)
    let (isLeaf, pathSegment) = hexPrefixDecode blobs[0]
    if isLeaf:
      return NodeRef(
        vType:     Leaf,
        lPfx:      pathSegment,
        lData:     PayloadRef(
          pType:   RawData,
          rawBlob: blobs[1]))
    else:
      var node = NodeRef(
        vType: Extension,
        ePfx:  pathSegment)
      node.key[0] = HashKey.fromBytes(blobs[1]).valueOr:
        return aristoError(RlpExtHashKeyExpected)
      return node
  of 17:
    for n in [0,1]:
      links[n] = HashKey.fromBytes(blobs[n]).valueOr:
        return aristoError(RlpBranchHashKeyExpected)
    return NodeRef(
      vType: Branch,
      key:   links)
  else:
    discard

  aristoError(Rlp2Or17ListEntries)


proc append*(writer: var RlpWriter; node: NodeRef) =
  ## Mixin for RLP writer. Note that a `Dummy` node is encoded as an empty
  ## list.
  func addHashKey(w: var RlpWriter; key: HashKey) =
    if 1 < key.len and key.len < 32:
      w.appendRawBytes key.data
    else:
      w.append key.data

  if node.error != AristoError(0):
    writer.startList(0)
  else:
    case node.vType:
    of Branch:
      writer.startList(17)
      for n in 0..15:
        writer.addHashKey node.key[n]
      writer.append EmptyBlob

    of Extension:
      writer.startList(2)
      writer.append node.ePfx.hexPrefixEncode(isleaf = false)
      writer.addHashKey node.key[0]

    of Leaf:
      proc getKey0(vid: VertexID): Result[HashKey,AristoError] {.noRaise.} =
        ok(node.key[0]) # always succeeds

      writer.startList(2)
      writer.append node.lPfx.hexPrefixEncode(isleaf = true)
      writer.append node.lData.serialise(getKey0).value

# ---------------------

proc digestTo*(node: NodeRef; T: type HashKey): T =
  ## Convert the argument `node` to the corresponding Merkle hash key
  rlp.encode(node).digestTo(HashKey)

proc serialise*(
    db: AristoDbRef;
    pyl: PayloadRef;
      ): Result[Blob,(VertexID,AristoError)] =
  ## Encode the data payload of the argument `pyl` as RLP `Blob` if it is of
  ## account type, otherwise pass the data as is.
  ##
  proc getKey(vid: VertexID): Result[HashKey,AristoError] =
    db.getKeyRc(vid)

  pyl.serialise getKey

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
