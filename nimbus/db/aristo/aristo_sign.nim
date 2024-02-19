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
  "."/[aristo_constants, aristo_desc, aristo_get, aristo_hashify, aristo_init,
       aristo_merge]

var noisy* = false

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc selfNoisy(w: bool): bool {.discardable.} =
  result = noisy
  noisy = w

proc hashifyNoisy(w: bool): bool {.discardable.} =
  when declared(aristo_hashify.noisy):
    aristo_hashify.setNoisy w
  else:
    false

proc mergeNoisy(w: bool): bool =
  when declared(aristo_merge.noisy):
    aristo_merge.setNoisy w
  else:
    false

# ------------------------------------------------------------------------------
# Public functions, signature generator
# ------------------------------------------------------------------------------

proc setNoisy*(w: bool): bool {.discardable.} =
  w.selfNoisy

template exec*(noisy: bool; code: untyped): untyped =
  block:
    let
      save = selfNoisy noisy
      save1 = hashifyNoisy noisy
      save2 = mergeNoisy noisy
    defer:
        selfNoisy save
        hashifyNoisy save1
        mergeNoisy save2
    code

proc merkleSignBegin*(
      ): MerkleSignRef =
  ## Start signature calculator for a list of key-value items.
  let
    db = AristoDbRef.init VoidBackendRef
    vid = VertexID(2)
  MerkleSignRef(
    root: vid,
    db:   db)

proc merkleSignAdd*(
    sdb: MerkleSignRef;
    key: openArray[byte];
    val: openArray[byte];
    ) =
  ## Add key-value item to the signature list. The order of the items to add
  ## is irrelevant.
  if sdb.error == AristoError(0):
    sdb.count.inc
    discard sdb.db.merge(sdb.root, key, val, VOID_PATH_ID).valueOr:
      sdb.`error` = error
      sdb.errKey = @key
      return

proc merkleSignCommit*(
    sdb: MerkleSignRef;
      ): Result[HashKey,(Blob,AristoError)] =
  ## Finish with the list, calculate signature and return it.
  if sdb.count == 0:
    return ok VOID_HASH_KEY
  if sdb.error != AristoError(0):
    return err((sdb.errKey, sdb.error))
  sdb.db.hashify().isOkOr:
    let w = (EmptyBlob, error[1])
    return err(w)
  let hash = sdb.db.getKeyRc(sdb.root).valueOr:
    let w = (EmptyBlob, error)
    return err(w)
  ok hash

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
