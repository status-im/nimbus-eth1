# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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

  AdminTabID* = distinct uint64
    ## Access keys for admin table records. When exposed (e.g. when itereating
    ## over the tables), this data type is to be used.

  GuestDbRef* = ref object of RootRef
    ## Object returned from `GuestDbFn` (if any)
    beKind*: BackendType             ## Backend type identifier

  TypedBackendRef* = ref TypedBackendObj
  TypedBackendObj* = object of BackendObj
    beKind*: BackendType             ## Backend type identifier
    when verifyIxId:
      txGen: uint                    ## Transaction ID generator (for debugging)
      txId: uint                     ## Active transaction ID (for debugging)

  TypedPutHdlErrRef* = ref object of RootRef
    case pfx*: StorageType           ## Error sub-table
    of VtxPfx:
      vid*: VertexID                 ## Vertex ID where the error occured
    of AdmPfx:
      aid*: AdminTabID
    of Oops:
      discard
    code*: AristoError               ## Error code (if any)
    info*: string                    ## Error description (if any)

  TypedPutHdlRef* = ref object of PutHdlRef
    error*: TypedPutHdlErrRef        ## Track error while collecting transaction
    when verifyIxId:
      txId: uint                     ## Transaction ID (for debugging)

const
  AdmTabIdTuv* = AdminTabID(0)       ## Access key for vertex ID generator state
  AdmTabIdLst* = AdminTabID(2)       ## Access key for last state

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

proc init*(
    T: type AristoDbRef;
    backend: BackendRef
      ): Result[T, AristoError] =
  let
    vTop = if backend == nil: VertexID(0) else: ?backend.getTuvFn()
    db = AristoDbRef(
      txRef: AristoTxRef(layer: LayerRef(vTop: vTop)),
      backend: backend,
      accLeaves: LruCache[Hash32, VertexRef].init(ACC_LRU_SIZE),
      stoLeaves: LruCache[Hash32, VertexRef].init(ACC_LRU_SIZE),
    )

  db.txRef.db = db # TODO evaluate if this cyclic ref is worth the convenience

  ok(db)

proc finish*(db: AristoDbRef; eradicate = false) =
  ## Backend destructor. The argument `eradicate` indicates that a full
  ## database deletion is requested. If set `false` the outcome might differ
  ## depending on the type of backend (e.g. the `BackendMemory` backend will
  ## always eradicate on close.)
  ##
  ## In case of distributed descriptors accessing the same backend, all
  ## distributed descriptors will be destroyed.
  ##
  ## This distructor may be used on already *destructed* descriptors.
  ##
  if not db.backend.isNil:
    db.backend.closeFn eradicate

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
