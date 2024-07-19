# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Sign Helper
## ========================
##
{.push raises: [].}

import
  eth/common,
  results,
  "."/
    [aristo_compute, aristo_desc, aristo_get, aristo_init, aristo_delete, aristo_merge]

# ------------------------------------------------------------------------------
# Public functions, signature generator
# ------------------------------------------------------------------------------

proc merkleSignBegin*(): MerkleSignRef =
  ## Start signature calculator for a list of key-value items.
  let
    db = AristoDbRef.init VoidBackendRef
    vid = VertexID(2)
  MerkleSignRef(root: vid, db: db)

proc merkleSignAdd*(sdb: MerkleSignRef, key: openArray[byte], val: openArray[byte]) =
  ## Add key-value item to the signature list. The order of the items to add
  ## is irrelevant.
  if sdb.error == AristoError(0):
    sdb.count.inc
    discard sdb.db.mergeGenericData(sdb.root, key, val).valueOr:
      sdb.`error` = error
      sdb.errKey = @key
      return

proc merkleSignDelete*(sdb: MerkleSignRef, key: openArray[byte]) =
  ## Add key-value item to the signature list. The order of the items to add
  ## is irrelevant.
  if sdb.error == AristoError(0):
    sdb.count.inc
    discard sdb.db.deleteGenericData(sdb.root, key).valueOr:
      sdb.`error` = error
      sdb.errKey = @key
      return

proc merkleSignCommit*(sdb: MerkleSignRef): Result[Hash256, (Blob, AristoError)] =
  ## Finish with the list, calculate signature and return it.
  if sdb.count == 0:
    return ok EMPTY_ROOTHASH
  if sdb.error != AristoError(0):
    return err((sdb.errKey, sdb.error))

  let sign = sdb.db.computeKey((sdb.root, sdb.root)).valueOr:
    if error == GetVtxNotFound:
      if not sdb.db.getVtx((sdb.root, sdb.root)).isValid:
        return ok EMPTY_ROOTHASH
    raiseAssert "merkleSignCommit(): " & $error

  ok sign.to(Hash256)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
