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
  ../aristo_desc/aristo_types_backend

const
  verifyIxId = true # and false
    ## Enforce session tracking

type
  AristoBackendType* = enum
    BackendNone        ## For providing backend-less constructor
    BackendMemory

  AristoTypedBackendRef* = ref object of AristoBackendRef
    kind*: AristoBackendType         ## Backend type identifier
    when verifyIxId:
      txGen: uint                    ## Transaction ID generator (for debugging)
      txId: uint                     ## Active transaction ID (for debugging)

  TypedPutHdlRef* = ref object of PutHdlRef
    when verifyIxId:
      txId: uint                     ## Transaction ID (for debugging)

  AristoStorageType* = enum
    ## Storage types, key prefix
    IdgPfx = 0                       ## ID generator
    VtxPfx = 1                       ## Vertex data
    KeyPfx = 2                       ## Key/hash data

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc beginSession*(hdl: TypedPutHdlRef; db: AristoTypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == 0
    if db.txGen == 0:
      db.txGen = 1
    db.txId = db.txGen
    hdl.txId = db.txGen
    db.txGen.inc

proc verifySession*(hdl: TypedPutHdlRef; db: AristoTypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == hdl.txId

proc finishSession*(hdl: TypedPutHdlRef; db: AristoTypedBackendRef) =
  when verifyIxId:
    doAssert db.txId == hdl.txId
    db.txId = 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
