# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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

  GetFilFn* =
    proc(qid: QueueID): Result[FilterRef,AristoError]
      {.gcsafe, raises: [].}
        ## Generic backend database retrieval function for a filter record.

  GetIdgFn* =
    proc(): Result[seq[VertexID],AristoError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function for a the ID generator
      ## `Aristo DB` state record.

  GetFqsFn* =
    proc(): Result[seq[(QueueID,QueueID)],AristoError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function for some filter queue
      ## administration data (e.g. the bottom/top ID.)

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

  PutFilFn* =
    proc(hdl: PutHdlRef; qf: openArray[(QueueID,FilterRef)])
      {.gcsafe, raises: [].}
        ## Generic backend database storage function for filter records.

  PutIdgFn* =
    proc(hdl: PutHdlRef; vs: openArray[VertexID])
      {.gcsafe, raises: [].}
        ## Generic backend database ID generator state storage function. This
        ## function replaces the current generator state.

  PutFqsFn* =
    proc(hdl: PutHdlRef; vs: openArray[(QueueID,QueueID)])
      {.gcsafe, raises: [].}
        ## Generic backend database filter ID state storage function. This
        ## function replaces the current filter ID list.

  PutEndFn* =
    proc(hdl: PutHdlRef): Result[void,AristoError] {.gcsafe, raises: [].}
      ## Generic transaction termination function

  # -------------

  CloseFn* =
    proc(flush: bool) {.gcsafe, raises: [].}
      ## Generic destructor for the `Aristo DB` backend. The argument `flush`
      ## indicates that a full database deletion is requested. If passed
      ## `false` the outcome might differ depending on the type of backend
      ## (e.g. in-memory backends would flush on close.)

  # -------------

  BackendRef* = ref object of RootRef
    ## Backend interface.
    filters*: QidSchedRef            ## Filter slot queue state

    getVtxFn*: GetVtxFn              ## Read vertex record
    getKeyFn*: GetKeyFn              ## Read Merkle hash/key
    getFilFn*: GetFilFn              ## Read back log filter
    getIdgFn*: GetIdgFn              ## Read vertex ID generator state
    getFqsFn*: GetFqsFn              ## Read filter ID state

    putBegFn*: PutBegFn              ## Start bulk store session
    putVtxFn*: PutVtxFn              ## Bulk store vertex records
    putKeyFn*: PutKeyFn              ## Bulk store vertex hashes
    putFilFn*: PutFilFn              ## Store back log filter
    putIdgFn*: PutIdgFn              ## Store ID generator state
    putFqsFn*: PutFqsFn              ## Store filter ID state
    putEndFn*: PutEndFn              ## Commit bulk store session

    closeFn*: CloseFn                ## Generic destructor

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
