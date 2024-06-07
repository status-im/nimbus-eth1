# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie builder, raw node insertion
## ======================================================
##
## This module merges `PathID` values as hexary lookup paths into the
## `Patricia Trie`. When changing vertices (aka nodes without Merkle hashes),
## associated (but separated) Merkle hashes will be deleted unless locked.
## Instead of deleting locked hashes error handling is applied.
##
## Also, nodes (vertices plus merkle hashes) can be added which is needed for
## boundary proofing after `snap/1` download. The vertices are split from the
## nodes and stored as-is on the table holding `Patricia Trie` entries. The
##  hashes are stored iin a separate table and the vertices are labelled
## `locked`.

{.push raises: [].}

import
  std/[strutils, sets, tables, typetraits],
  eth/[common, trie/nibbles],
  results,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_layers,
       aristo_path, aristo_utils],
  ./aristo_merge/[merge_payload_helper, merge_proof]

export
  merge_proof

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(
    rc: Result[Hike,AristoError];
    T: type Result[bool,AristoError];
      ): T =
  ## Return code converter
  if rc.isOk:
    ok true
  elif rc.error in {MergeLeafPathCachedAlready,
                    MergeLeafPathOnBackendAlready}:
    ok false
  else:
    err(rc.error)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergePayload*(
    db: AristoDbRef;                   # Database, top layer
    leafTie: LeafTie;                  # Leaf item to add to the database
    payload: PayloadRef;               # Payload value
    accPath: PathID;                   # Needed for accounts payload
      ): Result[Hike,AristoError] =
  ## Merge the argument `leafTie` key-value-pair into the top level vertex
  ## table of the database `db`. The field `path` of the `leafTie` argument is
  ## used to address the leaf vertex with the payload. It is stored or updated
  ## on the database accordingly.
  ##
  ## If the `leafTie` argument referes to aa account entrie (i.e. the
  ## `leafTie.root` equals `VertexID(1)`) and the leaf entry has already an
  ## `AccountData` payload, its `storageID` field must be the same as the one
  ## on the database. The `accPath` argument will be ignored.
  ##
  ## Otherwise, if the `root` argument belongs to a well known sub trie (i.e.
  ## it does not exceed `LEAST_FREE_VID`) the `accPath` argument is ignored
  ## and the entry will just be merged.
  ##
  ## Otherwise, a valid `accPath` (i.e. different from `VOID_PATH_ID`.) is
  ## required relating to an account leaf entry (starting at `VertexID(`)`).
  ## If the payload of that leaf entry is not of type `AccountData` it is
  ## ignored.
  ##
  ## Otherwise, if the sub-trie where the `leafTie` is to be merged into does
  ## not exist yes, the `storageID` field of the `accPath` leaf must have been
  ## reset to `storageID(0)` and will be updated accordingly on the database.
  ##
  ## Otherwise its `storageID` field must be equal to the `leafTie.root` vertex
  ## ID. So vertices can be marked for Merkle hash update.
  ##
  let wp = block:
    if leafTie.root.distinctBase < LEAST_FREE_VID:
      if not leafTie.root.isValid:
        return err(MergeRootMissing)
      VidVtxPair()
    else:
      let rc = db.registerAccount(leafTie.root, accPath)
      if rc.isErr:
        return err(rc.error)
      else:
        rc.value

  let hike = leafTie.hikeUp(db).to(Hike)
  var okHike: Hike
  if 0 < hike.legs.len:
    case hike.legs[^1].wp.vtx.vType:
    of Branch:
      okHike = ? db.mergePayloadTopIsBranchAddLeaf(hike, payload)
    of Leaf:
      if 0 < hike.tail.len:          # `Leaf` vertex problem?
        return err(MergeLeafGarbledHike)
      okHike = ? db.mergePayloadUpdate(hike, leafTie, payload)
    of Extension:
      okHike = ? db.mergePayloadTopIsExtAddLeaf(hike, payload)

  else:
    # Empty hike
    let rootVtx = db.getVtx hike.root
    if rootVtx.isValid:
      okHike = ? db.mergePayloadTopIsEmptyAddLeaf(hike,rootVtx, payload)

    else:
      # Bootstrap for existing root ID
      let wp = VidVtxPair(
        vid: hike.root,
        vtx: VertexRef(
          vType: Leaf,
          lPfx:  leafTie.path.to(NibblesSeq),
          lData: payload))
      db.setVtxAndKey(hike.root, wp.vid, wp.vtx)
      okHike = Hike(root: wp.vid, legs: @[Leg(wp: wp, nibble: -1)])

    # Double check the result until the code is more reliable
    block:
      let rc = okHike.to(NibblesSeq).pathToTag
      if rc.isErr or rc.value != leafTie.path:
        return err(MergeAssemblyFailed) # Ooops

  # Make sure that there is an accounts that refers to that storage trie
  if wp.vid.isValid and not wp.vtx.lData.account.storageID.isValid:
    let leaf = wp.vtx.dup # Dup on modify
    leaf.lData.account.storageID = leafTie.root
    db.layersPutVtx(VertexID(1), wp.vid, leaf)
    db.layersResKey(VertexID(1), wp.vid)

  ok okHike


proc mergePayload*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Even nibbled byte path
    payload: PayloadRef;               # Payload value
    accPath = VOID_PATH_ID;            # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(root,path)` arguments instead of a `LeafTie`
  ## object.
  let lty = LeafTie(root: root, path: ? path.pathToTag)
  db.mergePayload(lty, payload, accPath).to(typeof result)


proc merge*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # MPT state root
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
    accPath: PathID;                   # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(root,path)` arguments instead of a `LeafTie`.
  ## The argument `data` is stored as-is as a `RawData` payload value.
  let pyl = PayloadRef(pType: RawData, rawBlob: @data)
  db.mergePayload(root, path, pyl, accPath)

proc mergeAccount*(
    db: AristoDbRef;                   # Database, top layer
    path: openArray[byte];             # Leaf item to add to the database
    data: openArray[byte];             # Raw data payload value
      ): Result[bool,AristoError] =
  ## Variant of `merge()` for `(VertexID(1),path)` arguments instead of a
  ## `LeafTie`. The argument `data` is stored as-is as a `RawData` payload
  ## value.
  let pyl = PayloadRef(pType: RawData, rawBlob: @data)
  db.mergePayload(VertexID(1), path, pyl, VOID_PATH_ID)


proc mergeLeaf*(
    db: AristoDbRef;                   # Database, top layer
    leaf: LeafTiePayload;              # Leaf item to add to the database
    accPath = VOID_PATH_ID;            # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## Variant of `merge()`. This function will not indicate if the leaf
  ## was cached, already.
  db.mergePayload(leaf.leafTie,leaf.payload, accPath).to(typeof result)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
