# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  ../aristo_desc/aristo_types_backend

const
  verifyIxId = true # and false
    ## Enforce session tracking

type
  AristoBackendType* = enum
    BackendVoid                      ## For providing backend-less constructor
    BackendMemory
    BackendRocksDB

  AristoStorageType* = enum
    ## Storage types, key prefix
    Oops = 0
    IdgPfx = 1                       ## ID generator
    VtxPfx = 2                       ## Vertex data
    KeyPfx = 3                       ## Key/hash data

  TypedBackendRef* = ref object of AristoBackendRef
    kind*: AristoBackendType         ## Backend type identifier
    when verifyIxId:
      txGen: uint                    ## Transaction ID generator (for debugging)
      txId: uint                     ## Active transaction ID (for debugging)

  TypedPutHdlErrRef* = ref object of RootRef
    case pfx*: AristoStorageType     ## Error sub-table
    of VtxPfx, KeyPfx:
      vid*: VertexID                 ## Vertex ID where the error occured
    of IdgPfx, Oops:
      discard
    code*: AristoError               ## Error code (if any)

  TypedPutHdlRef* = ref object of PutHdlRef
    error*: TypedPutHdlErrRef        ## Track error while collecting transaction
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
