# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.
{.push raises: [].}

import
  ../aristo_desc,
  ../aristo_desc/desc_backend

const
  verifyIxId = true # and false
    ## Enforce session tracking

type
  BackendType* = enum
    BackendVoid = 0                  ## For providing backend-less constructor
    BackendMemory
    BackendRocksDB

  StorageType* = enum
    ## Storage types, key prefix
    Oops = 0
    AdmPfx = 1                       ## Admin data, e.g. ID generator
    VtxPfx = 2                       ## Vertex data
    KeyPfx = 3                       ## Key/hash data
    FilPfx = 4                       ## Filter logs (to revert to earlier state)

  AdminTabID* = distinct uint64
    ## Access keys for admin table records. When exposed (e.g. when itereating
    ## over the tables), this data type is to be used.

  TypedBackendRef* = ref object of BackendRef
    beKind*: BackendType             ## Backend type identifier
    when verifyIxId:
      txGen: uint                    ## Transaction ID generator (for debugging)
      txId: uint                     ## Active transaction ID (for debugging)

  TypedPutHdlErrRef* = ref object of RootRef
    case pfx*: StorageType           ## Error sub-table
    of VtxPfx, KeyPfx:
      vid*: VertexID                 ## Vertex ID where the error occured
    of FilPfx:
      qid*: QueueID                  ## Ditto
    of AdmPfx, Oops:
      discard
    code*: AristoError               ## Error code (if any)

  TypedPutHdlRef* = ref object of PutHdlRef
    error*: TypedPutHdlErrRef        ## Track error while collecting transaction
    when verifyIxId:
      txId: uint                     ## Transaction ID (for debugging)

const
  AdmTabIdIdg* = AdminTabID(0)       ## Access key for vertex ID generator state
  AdmTabIdFqs* = AdminTabID(1)       ## Access key for filter queue states

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
