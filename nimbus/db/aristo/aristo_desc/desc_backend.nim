# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie backend data access
## ==============================================
##

{.push raises: [].}

import
  results,
  "."/[desc_error, desc_identifiers, desc_structural]

type
  GetVtxFn* =
    proc(vid: VertexID): Result[VertexRef,AristoError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function for a single structural
      ## `Aristo DB` data record.

  GetKeyFn* =
    proc(vid: VertexID): Result[HashKey,AristoError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function for a single
      ## `Aristo DB` hash lookup value.

  GetIdgFn* =
    proc(): Result[seq[VertexID],AristoError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function for a the ID generator
      ## `Aristo DB` state record.

  GetLstFn* =
    proc(): Result[SavedState,AristoError]
      {.gcsafe, raises: [].}
        ## Generic last recorded state stamp retrieval function

  # -------------

  PutHdlRef* = ref object of RootRef
    ## Persistent database transaction frame handle. This handle is used to
    ## wrap any of `PutVtxFn`, `PutKeyFn`, and `PutIdgFn` into and atomic
    ## transaction frame. These transaction frames must not be interleaved
    ## by any library function using the backend.

  PutBegFn* =
    proc(): PutHdlRef {.gcsafe, raises: [].}
      ## Generic transaction initialisation function

  PutVtxFn* =
    proc(hdl: PutHdlRef; vrps: openArray[(VertexID,VertexRef)])
      {.gcsafe, raises: [].}
        ## Generic backend database bulk storage function, `VertexRef(nil)`
        ## values indicate that records should be deleted.

  PutKeyFn* =
    proc(hdl: PutHdlRef; vkps: openArray[(VertexID,HashKey)])
      {.gcsafe, raises: [].}
        ## Generic backend database bulk storage function, `VOID_HASH_KEY`
        ## values indicate that records should be deleted.

  PutIdgFn* =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])
      {.gcsafe, raises: [].}
        ## Generic backend database ID generator state storage function. This
        ## function replaces the current generator state.

  PutLstFn* =
    proc(hdl: PutHdlRef; lst: SavedState)
      {.gcsafe, raises: [].}
        ## Generic last recorded state stamp storage function. This
        ## function replaces the currentlt saved state.

  PutEndFn* =
    proc(hdl: PutHdlRef): Result[void,AristoError] {.gcsafe, raises: [].}
      ## Generic transaction termination function

  # -------------

  GuestDbFn* =
    proc(instance: int): Result[RootRef,AristoError] {.gcsafe, raises: [].}
      ## Generic function that returns a compartmentalised database handle that
      ## can be used by another application. If non-nil, this handle allows to
      ## use a previously allocated database. It is separated from the `Aristo`
      ## columns.
      ##
      ## A successful return value might be `nil` if this feature is
      ## unsupported.
      ##
      ## Caveat:
      ##  The guest database is closed automatically when closing the `Aristo`
      ##  database.

  CloseFn* =
    proc(flush: bool) {.gcsafe, raises: [].}
      ## Generic destructor for the `Aristo DB` backend. The argument `flush`
      ## indicates that a full database deletion is requested. If passed
      ## `false` the outcome might differ depending on the type of backend
      ## (e.g. in-memory backends would flush on close.)

  # -------------

  BackendRef* = ref BackendObj
  BackendObj* = object of RootObj
    ## Backend interface.
    getVtxFn*: GetVtxFn              ## Read vertex record
    getKeyFn*: GetKeyFn              ## Read Merkle hash/key
    getIdgFn*: GetIdgFn              ## Read vertex ID generator state
    getLstFn*: GetLstFn              ## Read saved state

    putBegFn*: PutBegFn              ## Start bulk store session
    putVtxFn*: PutVtxFn              ## Bulk store vertex records
    putKeyFn*: PutKeyFn              ## Bulk store vertex hashes
    putIdgFn*: PutIdgFn              ## Store ID generator state
    putLstFn*: PutLstFn              ## Store saved state
    putEndFn*: PutEndFn              ## Commit bulk store session

    guestDbFn*: GuestDbFn            ## Piggyback DB for another application
    closeFn*: CloseFn                ## Generic destructor

proc init*(trg: var BackendObj; src: BackendObj) =
  trg.getVtxFn = src.getVtxFn
  trg.getKeyFn = src.getKeyFn
  trg.getIdgFn = src.getIdgFn
  trg.getLstFn = src.getLstFn

  trg.putBegFn = src.putBegFn
  trg.putVtxFn = src.putVtxFn
  trg.putKeyFn = src.putKeyFn
  trg.putIdgFn = src.putIdgFn
  trg.putLstFn = src.putLstFn
  trg.putEndFn = src.putEndFn

  trg.guestDbFn = src.guestDbFn
  trg.closeFn = src.closeFn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
