# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  results,
  ./desc_error

type
  GetKvpFn* =
    proc(key: openArray[byte]): Result[seq[byte],KvtError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function
  LenKvpFn* =
    proc(key: openArray[byte]): Result[int,KvtError] {.gcsafe, raises: [].}
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
    proc(hdl: PutHdlRef; k, v: openArray[byte]) {.gcsafe, raises: [].}
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

  # -------------

  BackendRef* = ref BackendObj
  BackendObj* = object of RootObj
    ## Backend interface.

    getKvpFn*: GetKvpFn              ## Read key-value pair
    lenKvpFn*: LenKvpFn              ## Read key-value pair length

    putBegFn*: PutBegFn              ## Start bulk store session
    putKvpFn*: PutKvpFn              ## Bulk store key-value pairs
    putEndFn*: PutEndFn              ## Commit bulk store session

    closeFn*: CloseFn                ## Generic destructor

proc init*(trg: var BackendObj; src: BackendObj) =
  trg.getKvpFn = src.getKvpFn
  trg.lenKvpFn = src.lenKvpFn
  trg.putBegFn = src.putBegFn
  trg.putKvpFn = src.putKvpFn
  trg.putEndFn = src.putEndFn
  trg.closeFn = src.closeFn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
