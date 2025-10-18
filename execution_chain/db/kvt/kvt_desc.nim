# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- key-value table
## =========================
##
{.push raises: [].}

import
  std/[hashes, tables],
  results,
  ./kvt_init/init_common,
  ./kvt_constants,
  ./kvt_desc/desc_error

# Not auto-exporting backend
export
  hashes, tables, kvt_constants, desc_error

type
  GetKvpFn* =
    proc(key: openArray[byte]): Result[seq[byte],KvtError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function
  LenKvpFn* =
    proc(key: openArray[byte]): Result[int,KvtError] {.gcsafe, raises: [].}
      ## Generic backend database retrieval function

  # -------------

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

  GetBackendFn* =
    proc(): TypedBackendRef {.gcsafe, raises: [].}
      ## Get a reference to typed backend.

  KvtTxRef* = ref object
    ## Transaction descriptor
    db*: KvtDbRef                     ## Database descriptor
    parent*: KvtTxRef                 ## Previous transaction
    sTab*: Table[seq[byte],seq[byte]] ## Structural data table

  KvtDbRef* = ref object of RootRef
    ## Backend interface.
    getKvpFn*: GetKvpFn              ## Read key-value pair
    lenKvpFn*: LenKvpFn              ## Read key-value pair length

    putBegFn*: PutBegFn              ## Start bulk store session
    putKvpFn*: PutKvpFn              ## Bulk store key-value pairs
    putEndFn*: PutEndFn              ## Commit bulk store session

    closeFn*: CloseFn                ## Generic destructor

    getBackendFn*: GetBackendFn

    txRef*: KvtTxRef
      ## Tx holding data scheduled to be written to disk during the next
      ## `persist` call

  KvtType* {.pure.}  = enum
    Generic = "KvtGen"            ## Generic kvt
    Synchro = "KvtSync"           ## Syncer block headers kvt
    ContractCode = "KvtCode"      ## Contract code kvt
    Witness = "KvtWitness"        ## Witness kvt

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func getOrVoid*(tab: Table[seq[byte],seq[byte]]; w: seq[byte]): seq[byte] =
  tab.getOrDefault(w, EmptyBlob)

func isValid*(key: seq[byte]): bool =
  key != EmptyBlob

func isValid*(tx: KvtTxRef): bool =
  tx != KvtTxRef(nil)

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Don't put in a hash!
func hash*(db: KvtDbRef): Hash {.error.}

iterator stack*(tx: KvtTxRef): KvtTxRef =
  # Stack going from base to tx
  var frames: seq[KvtTxRef]
  var tx = tx
  while tx != nil:
    frames.add tx
    tx = tx.parent

  while frames.len > 0:
    yield frames.pop()

iterator rstack*(tx: KvtTxRef): KvtTxRef =
  var tx = tx
  # Stack in reverse order
  while tx != nil:
    yield tx
    tx = tx.parent

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
