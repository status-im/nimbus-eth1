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
  ../kvt_desc,
  ../kvt_desc/desc_backend

const
  verifyIxId = true # and false
    ## Enforce session tracking

type
  BackendType* = enum
    BackendVoid = 0                  ## For providing backend-less constructor
    BackendMemory                    ## Same as Aristo
    BackendRocksDB                   ## Same as Aristo
    BackendRdbTriggered              ## Piggybacked on remote write session

  TypedBackendRef* = ref TypedBackendObj
  TypedBackendObj* = object of BackendObj
    beKind*: BackendType             ## Backend type identifier
    when verifyIxId:
      txGen: uint                    ## Transaction ID generator (for debugging)
      txId: uint                     ## Active transaction ID (for debugging)

  TypedPutHdlRef* = ref object of PutHdlRef
    error*: KvtError                 ## Track error while collecting transaction
    info*: string                    ##  Error description (if any)
    when verifyIxId:
      txId: uint                     ## Transaction ID (for debugging)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc beginSession*(hdl: TypedPutHdlRef; db: TypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == 0
    if db.txGen == 0:
      db.txGen = 1
    db.txId = db.txGen
    hdl.txId = db.txGen
    db.txGen.inc

proc verifySession*(hdl: TypedPutHdlRef; db: TypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == hdl.txId

proc finishSession*(hdl: TypedPutHdlRef; db: TypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == hdl.txId
    db.txId = 0

proc init*(trg: var TypedBackendObj; src: TypedBackendObj) =
  desc_backend.init(trg, src)
  trg.beKind = src.beKind
  when verifyIxId:
    trg.txGen = src.txGen
    trg.txId = src.txId

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
