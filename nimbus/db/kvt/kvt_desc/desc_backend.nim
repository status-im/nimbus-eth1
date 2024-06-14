# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- backend data types
## ============================
##

{.push raises: [].}

import
  eth/common,
  results,
  ./desc_error

type
  GetKvpFn* =
    proc(key: openArray[byte]): Result[Blob,KvtError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function

  # -------------

  PutHdlRef* = ref object of RootRef
    ## Persistent database transaction frame handle. This handle is used to
    ## wrap any of `PutVtxFn`, `PutKeyFn`, and `PutIdgFn` into and atomic
    ## transaction frame. These transaction frames must not be interleaved
    ## by any library function using the backend.

  PutBegFn* =
    proc(): Result[PutHdlRef,KvtError] {.gcsafe, raises: [].}
      ## Generic transaction initialisation function

  PutKvpFn* =
    proc(hdl: PutHdlRef; kvps: openArray[(Blob,Blob)]) {.gcsafe, raises: [].}
      ## Generic backend database bulk storage function.

  PutEndFn* =
    proc(hdl: PutHdlRef): Result[void,KvtError] {.gcsafe, raises: [].}
      ## Generic transaction termination function

  # -------------

  CloseFn* =
    proc(eradicate: bool) {.gcsafe, raises: [].}
      ## Generic destructor for the `Kvt DB` backend. The argument `eradicate`
      ## indicates that a full database deletion is requested. If passed
      ## `false` the outcome might differ depending on the type of backend
      ## (e.g. in-memory backends would eradicate on close.)

  CanModFn* =
    proc(): Result[void,KvtError] {.gcsafe, raises: [].}
      ## This function returns OK if there is nothing to prevent the main
      ## `KVT` descriptors being modified (e.g. by `reCentre()`) or by
      ## adding/removing a new peer (e.g. by `fork()` or `forget()`.)

  SetWrReqFn* =
    proc(db: RootRef): Result[void,KvtError] {.gcsafe, raises: [].}
      ## This function stores a request function for the piggiback mode
      ## writing to the `Aristo` set of column families.
      ##
      ## If used at all, this function would run thee function closure
      ## `rocks_db.setWrReqTriggeredFn()()` with a `KvtDbRef` type argument
      ## for `db`. This allows to run the `Kvt` without linking to the
      ## rocksdb interface unless it is really needed.

  # -------------

  BackendRef* = ref BackendObj
  BackendObj* = object of RootObj
    ## Backend interface.

    getKvpFn*: GetKvpFn              ## Read key-value pair

    putBegFn*: PutBegFn              ## Start bulk store session
    putKvpFn*: PutKvpFn              ## Bulk store key-value pairs
    putEndFn*: PutEndFn              ## Commit bulk store session

    closeFn*: CloseFn                ## Generic destructor
    canModFn*: CanModFn              ## Lock-alike

    setWrReqFn*: SetWrReqFn          ## Register main descr for write request

proc init*(trg: var BackendObj; src: BackendObj) =
  trg.getKvpFn = src.getKvpFn
  trg.putBegFn = src.putBegFn
  trg.putKvpFn = src.putKvpFn
  trg.putEndFn = src.putEndFn
  trg.closeFn = src.closeFn
  trg.canModFn = src.canModFn
  trg.setWrReqFn = src.setWrReqFn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
