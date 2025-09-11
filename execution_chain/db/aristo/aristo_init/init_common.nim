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

type
  BackendType* = enum
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

  TypedBackendRef* = ref object of RootObj
    beKind*: BackendType             ## Backend type identifier

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

const
  AdmTabIdTuv* = AdminTabID(0)       ## Access key for vertex ID generator state
  AdmTabIdLst* = AdminTabID(2)       ## Access key for last state

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc initInstance*(db: AristoDbRef): Result[void, AristoError] =
  let vTop = (?db.getLstFn()).vTop
  db.txRef = AristoTxRef(db: db, vTop: vTop, snapshot: Snapshot(level: Opt.some(0)))
  db.accLeaves = LruCache[Hash32, AccLeafRef].init(ACC_LRU_SIZE)
  db.stoLeaves = LruCache[Hash32, StoLeafRef].init(ACC_LRU_SIZE)
  ok()

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
  db.closeFn eradicate

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
