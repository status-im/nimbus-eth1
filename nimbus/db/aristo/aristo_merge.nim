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
  std/[strutils, sets, tables],
  eth/common,
  results,
  "."/[aristo_desc, aristo_hike, aristo_path],
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
  elif rc.error in {MergeLeafPathCachedAlready, MergeLeafPathOnBackendAlready}:
    ok false
  else:
    err(rc.error)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

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
  db.mergePayloadImpl(lty, payload, accPath).to(typeof result)


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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
