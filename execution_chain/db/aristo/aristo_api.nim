# nimbus-eth1
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Stackable API for `Aristo`
## ==========================


import
  std/times,
  eth/common/hashes,
  results,
  ./aristo_desc/desc_backend,
  ./aristo_init/memory_db,
  ./aristo_init/memory_only,
  ./aristo_init/init_common,
  "."/[aristo_delete, aristo_desc, aristo_fetch, aristo_merge,
       aristo_part, aristo_path, aristo_persist, aristo_profile, aristo_tx_frame]

export
  AristoDbProfListRef

const
  AutoValidateApiHooks = defined(release).not
    ## No validatinon needed for production suite.

  AristoPersistentBackendOk = AutoValidateApiHooks # and false
    ## Set true for persistent backend profiling (which needs an extra
    ## link library.)

when AristoPersistentBackendOk:
  import ./aristo_init/rocks_db

# Annotation helper(s)
{.pragma: noRaise, gcsafe, raises: [].}

type
  AristoApiCheckpointFn* =
    proc(tx: AristoTxRef;
        blockNumber: uint64
        ) {.noRaise.}
      ## Update the txFrame to the given checkpoint "identifier", or block number

  AristoApiDeleteAccountRecordFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Delete the account leaf entry addressed by the argument `path`. If
      ## this leaf entry referres to a storage tree, this one will be deleted
      ## as well.

  AristoApiDeleteStorageDataFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
         stoPath: Hash32;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For a given account argument `accPath`, this function deletes the
      ## argument `stoPath` from the associated storage tree (if any, at all.)
      ## If the if the argument `stoPath` deleted was the last one on the
      ## storage tree, account leaf referred to by `accPath` will be updated
      ## so that it will not refer to a storage tree anymore. In the latter
      ## case only the function will return `true`.

  AristoApiDeleteStorageTreeFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Variant of `deleteStorageData()` for purging the whole storage tree
      ## associated to the account argument `accPath`.

  AristoApiFetchLastCheckpointFn* =
    proc(db: AristoTxRef
        ): Result[uint64,AristoError]
        {.noRaise.}
      ## The function returns the state of the last saved state. This is a
      ## Merkle hash tag for vertex with ID 1 and a bespoke `uint64` identifier
      ## (may be interpreted as block number.)

  AristoApiFetchAccountRecordFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
        ): Result[AristoAccount,AristoError]
        {.noRaise.}
      ## Fetch an account record from the database indexed by `accPath`.

  AristoApiFetchStateRootFn* =
    proc(db: AristoTxRef;
        ): Result[Hash32,AristoError]
        {.noRaise.}
      ## Fetch the Merkle hash of the account root.

  AristoApiFetchStorageDataFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
         stoPath: Hash32;
        ): Result[UInt256,AristoError]
        {.noRaise.}
      ## For a storage tree related to account `accPath`, fetch the data
      ## record from the database indexed by `stoPath`.

  AristoApiFetchStorageRootFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
        ): Result[Hash32,AristoError]
        {.noRaise.}
      ## Fetch the Merkle hash of the storage root related to `accPath`.

  AristoApiFinishFn* =
    proc(db: AristoDbRef;
         eradicate = false;
        ) {.noRaise.}
      ## Backend destructor. The argument `eradicate` indicates that a full
      ## database deletion is requested. If set `false` the outcome might
      ## differ depending on the type of backend (e.g. the `BackendMemory`
      ## backend will always eradicate on close.)
      ##
      ## In case of distributed descriptors accessing the same backend, all
      ## distributed descriptors will be destroyed.
      ##
      ## This distructor may be used on already *destructed* descriptors.

  AristoApiForgetFn* =
    proc(db: AristoTxRef;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Destruct the non centre argument `db` descriptor (see comments on
      ## `reCentre()` for details.)
      ##
      ## A non centre descriptor should always be destructed after use (see
      ## also# comments on `fork()`.)

  AristoApiHashifyFn* =
    proc(db: AristoTxRef;
        ): Result[void,(VertexID,AristoError)]
        {.noRaise.}
      ## Add keys to the  `Patricia Trie` so that it becomes a `Merkle
      ## Patricia Tree`.

  AristoApiHasPathAccountFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For an account record indexed by `accPath` query whether this record
      ## exists on the database.

  AristoApiHasPathStorageFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
         stoPath: Hash32;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For a storage tree related to account `accPath`, query whether the
      ## data record indexed by `stoPath` exists on the database.

  AristoApiHasStorageDataFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For a storage tree related to account `accPath`, query whether there
      ## is a non-empty data storage area at all.

  AristoApiMergeAccountRecordFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
         accRec: AristoAccount;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## Merge the  key-value-pair argument `(accKey,accRec)` as an account
      ## ledger value, i.e. the the sub-tree starting at `VertexID(1)`.
      ##
      ## On success, the function returns `true` if the `accPath` argument was
      ## not on the database already or the value differend from `accRec`, and
      ## `false` otherwise.

  AristoApiMergeStorageDataFn* =
    proc(db: AristoTxRef;
         accPath: Hash32;
         stoPath: Hash32;
         stoData: UInt256;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Store the `stoData` data argument on the storage area addressed by
      ## `(accPath,stoPath)` where `accPath` is the account key (into the MPT)
      ## and `stoPath`  is the slot path of the corresponding storage area.

  AristoApiPartAccountTwig* =
    proc(db: AristoTxRef;
         accPath: Hash32;
        ): Result[(seq[seq[byte]],bool), AristoError]
        {.noRaise.}
      ## This function returns a chain of rlp-encoded nodes along the argument
      ## path `(root,path)` followed by a `true` value if the `path` argument
      ## exists in the database. If the argument `path` is not on the database,
      ## a partial path will be returned follwed by a `false` value.
      ##
      ## Errors will only be returned for invalid paths.

  AristoApiPartStorageTwig* =
    proc(db: AristoTxRef;
         accPath: Hash32;
         stoPath: Hash32;
        ): Result[(seq[seq[byte]],bool), AristoError]
        {.noRaise.}
      ## Variant of `partAccountTwig()`. Note that the function always returns
      ## an error unless the `accPath` is valid.

  AristoApiPartUntwigPath* =
    proc(chain: openArray[seq[byte]];
         root: Hash32;
         path: Hash32;
        ): Result[Opt[seq[byte]],AristoError]
        {.noRaise.}
      ## Variant of `partUntwigGeneric()`.

  AristoApiPartUntwigPathOk* =
    proc(chain: openArray[seq[byte]];
         root: Hash32;
         path: Hash32;
         payload: Opt[seq[byte]];
        ): Result[void,AristoError]
        {.noRaise.}
      ## Variant of `partUntwigGenericOk()`.

  AristoApiPathAsBlobFn* =
    proc(tag: PathID;
        ): seq[byte]
        {.noRaise.}
      ## Converts the `tag` argument to a sequence of an even number of
      ## nibbles represented by a `seq[byte]`. If the argument `tag` represents
      ## an odd number of nibbles, a zero nibble is appendend.
      ##
      ## This function is useful only if there is a tacit agreement that all
      ## paths used to index database leaf values can be represented as
      ## `seq[byte]`, i.e. `PathID` type paths with an even number of nibbles.

  AristoApiPersistFn* =
    proc(
      db: AristoDbRef;
      batch: PutHdlRef;
      txFrame: AristoTxRef;
        ) {.noRaise.}
      ## Persistently store the cumulative set of changes that `txFrame`
      ## represents to the database. `txFrame` becomes the new base after this
      ## operation.

  AristoApiDisposeFn* =
    proc(tx: AristoTxRef;
        ) {.noRaise.}
      ## Release a frame releasing its associated resources. This operation
      ## makes all frames built on top of it invalid - they still need to be
      ## released however.

  AristoApiTxFrameBeginFn* =
    proc(db: AristoDbRef; parent: AristoTxRef
        ): AristoTxRef
        {.noRaise.}
      ## Create a new layered transaction frame - the frame can later be
      ## released or frozen and persisted.

  AristoApiBaseTxFrameFn* =
    proc(db: AristoDbRef;
        ): AristoTxRef
        {.noRaise.}

  AristoApiRef* = ref AristoApiObj
  AristoApiObj* = object of RootObj
    ## Useful set of `Aristo` fuctions that can be filtered, stacked etc.
    checkpoint*: AristoApiCheckpointFn

    deleteAccountRecord*: AristoApiDeleteAccountRecordFn
    deleteStorageData*: AristoApiDeleteStorageDataFn
    deleteStorageTree*: AristoApiDeleteStorageTreeFn

    fetchLastCheckpoint*: AristoApiFetchLastCheckpointFn

    fetchAccountRecord*: AristoApiFetchAccountRecordFn
    fetchStateRoot*: AristoApiFetchStateRootFn
    fetchStorageData*: AristoApiFetchStorageDataFn
    fetchStorageRoot*: AristoApiFetchStorageRootFn

    finish*: AristoApiFinishFn
    hasPathAccount*: AristoApiHasPathAccountFn
    hasPathStorage*: AristoApiHasPathStorageFn
    hasStorageData*: AristoApiHasStorageDataFn

    mergeAccountRecord*: AristoApiMergeAccountRecordFn
    mergeStorageData*: AristoApiMergeStorageDataFn

    partAccountTwig*: AristoApiPartAccountTwig
    partStorageTwig*: AristoApiPartStorageTwig
    partUntwigPath*: AristoApiPartUntwigPath
    partUntwigPathOk*: AristoApiPartUntwigPathOk

    pathAsBlob*: AristoApiPathAsBlobFn
    persist*: AristoApiPersistFn
    dispose*: AristoApiDisposeFn
    txFrameBegin*: AristoApiTxFrameBeginFn
    baseTxFrame*: AristoApiBaseTxFrameFn


  AristoApiProfNames* = enum
    ## Index/name mapping for profile slots
    AristoApiProfTotal                  = "total"
    AristoApiProfCheckpointFn           = "checkpoint"

    AristoApiProfDeleteAccountRecordFn  = "deleteAccountRecord"
    AristoApiProfDeleteStorageDataFn    = "deleteStorageData"
    AristoApiProfDeleteStorageTreeFn    = "deleteStorageTree"

    AristoApiProfFetchLastCheckpointFn  = "fetchLastCheckpoint"

    AristoApiProfFetchAccountRecordFn   = "fetchAccountRecord"
    AristoApiProfFetchStateRootFn = "fetchStateRoot"
    AristoApiProfFetchStorageDataFn     = "fetchStorageData"
    AristoApiProfFetchStorageRootFn     = "fetchStorageRoot"

    AristoApiProfFinishFn               = "finish"

    AristoApiProfHasPathAccountFn       = "hasPathAccount"
    AristoApiProfHasPathStorageFn       = "hasPathStorage"
    AristoApiProfHasStorageDataFn       = "hasStorageData"

    AristoApiProfMergeAccountRecordFn   = "mergeAccountRecord"
    AristoApiProfMergeStorageDataFn     = "mergeStorageData"

    AristoApiProfPartAccountTwigFn      = "partAccountTwig"
    AristoApiProfPartStorageTwigFn      = "partStorageTwig"
    AristoApiProfPartUntwigPathFn       = "partUntwigPath"
    AristoApiProfPartUntwigPathOkFn     = "partUntwigPathOk"

    AristoApiProfPathAsBlobFn           = "pathAsBlob"
    AristoApiProfPersistFn              = "persist"
    AristoApiProfDisposeFn              = "dispose"
    AristoApiProfTxFrameBeginFn         = "txFrameBegin"
    AristoApiProfBaseTxFrameFn          = "baseTxFrame"

    AristoApiProfBeGetVtxFn             = "be/getVtx"
    AristoApiProfBeGetKeyFn             = "be/getKey"
    AristoApiProfBeGetTuvFn             = "be/getTuv"
    AristoApiProfBeGetLstFn             = "be/getLst"
    AristoApiProfBePutVtxFn             = "be/putVtx"
    AristoApiProfBePutTuvFn             = "be/putTuv"
    AristoApiProfBePutLstFn             = "be/putLst"
    AristoApiProfBePutEndFn             = "be/putEnd"

  AristoApiProfRef* = ref object of AristoApiRef
    ## Profiling API extension of `AristoApiObj`
    data*: AristoDbProfListRef
    be*: BackendRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when AutoValidateApiHooks:
  proc validate(api: AristoApiObj) =
    for _, field in api.fieldPairs():
      doAssert not field.isNil

  proc validate(prf: AristoApiProfRef) =
    prf.AristoApiRef[].validate
    doAssert not prf.data.isNil

proc dup(be: BackendRef): BackendRef =
  case be.kind:
  of BackendMemory:
    return MemBackendRef(be).dup

  of BackendRocksDB:
    when AristoPersistentBackendOk:
      return RdbBackendRef(be).dup

# ------------------------------------------------------------------------------
# Public API constuctors
# ------------------------------------------------------------------------------

func init*(api: var AristoApiObj) =
  ## Initialise an `api` argument descriptor
  ##
  when AutoValidateApiHooks:
    api.reset
  api.checkpoint = checkpoint

  api.deleteAccountRecord = deleteAccountRecord
  api.deleteStorageData = deleteStorageData
  api.deleteStorageTree = deleteStorageTree

  api.fetchLastCheckpoint = fetchLastCheckpoint

  api.fetchAccountRecord = fetchAccountRecord
  api.fetchStateRoot = fetchStateRoot
  api.fetchStorageData = fetchStorageData
  api.fetchStorageRoot = fetchStorageRoot

  api.finish = finish

  api.hasPathAccount = hasPathAccount
  api.hasPathStorage = hasPathStorage
  api.hasStorageData = hasStorageData

  api.mergeAccountRecord = mergeAccountRecord
  api.mergeStorageData = mergeStorageData

  api.partAccountTwig = partAccountTwig
  api.partStorageTwig = partStorageTwig
  api.partUntwigPath = partUntwigPath
  api.partUntwigPathOk = partUntwigPathOk

  api.pathAsBlob = pathAsBlob
  api.persist = persist
  api.dispose = dispose
  api.txFrameBegin = txFrameBegin
  api.baseTxFrame = baseTxFrame

  when AutoValidateApiHooks:
    api.validate

func init*(T: type AristoApiRef): T =
  new result
  result[].init()

func dup*(api: AristoApiRef): AristoApiRef =
  result = AristoApiRef()
  result[] = api[]
  when AutoValidateApiHooks:
    result[].validate

# ------------------------------------------------------------------------------
# Public profile API constuctor
# ------------------------------------------------------------------------------

func init*(
    T: type AristoApiProfRef;
    api: AristoApiRef;
    be = BackendRef(nil);
      ): T =
  ## This constructor creates a profiling API descriptor to be derived from
  ## an initialised `api` argument descriptor. For profiling the DB backend,
  ## the field `.be` of the result descriptor must be assigned to the
  ## `.backend` field of the `AristoTxRef` descriptor.
  ##
  ## The argument desctiptors `api` and `be` will not be modified and can be
  ## used to restore the previous set up.
  ##
  let
    data = AristoDbProfListRef(
      list: newSeq[AristoDbProfData](1 + high(AristoApiProfNames).ord))
    profApi = T(data: data)

  template profileRunner(n: AristoApiProfNames, code: untyped): untyped =
    let start = getTime()
    code
    data.update(n.ord, getTime() - start)

  profApi.checkpoint =
    proc(a: AristoTxRef): auto =
      AristoApiProfCheckpointFn.profileRunner:
        api.checkpoint(a)

  profApi.deleteAccountRecord =
    proc(a: AristoTxRef; b: Hash32): auto =
      AristoApiProfDeleteAccountRecordFn.profileRunner:
        result = api.deleteAccountRecord(a, b)

  profApi.deleteStorageData =
    proc(a: AristoTxRef; b: Hash32, c: Hash32): auto =
      AristoApiProfDeleteStorageDataFn.profileRunner:
        result = api.deleteStorageData(a, b, c)

  profApi.deleteStorageTree =
    proc(a: AristoTxRef; b: Hash32): auto =
      AristoApiProfDeleteStorageTreeFn.profileRunner:
        result = api.deleteStorageTree(a, b)

  profApi.fetchLastCheckpoint =
    proc(a: AristoTxRef): auto =
      AristoApiProfFetchLastCheckpointFn.profileRunner:
        result = api.fetchLastCheckpoint(a)

  profApi.fetchAccountRecord =
    proc(a: AristoTxRef; b: Hash32): auto =
      AristoApiProfFetchAccountRecordFn.profileRunner:
        result = api.fetchAccountRecord(a, b)

  profApi.fetchStateRoot =
    proc(a: AristoTxRef; b: bool): auto =
      AristoApiProfFetchStateRootFn.profileRunner:
        result = api.fetchStateRoot(a, b)

  profApi.fetchStorageData =
    proc(a: AristoTxRef; b, stoPath: Hash32): auto =
      AristoApiProfFetchStorageDataFn.profileRunner:
        result = api.fetchStorageData(a, b, stoPath)

  profApi.fetchStorageRoot =
    proc(a: AristoTxRef; b: Hash32): auto =
      AristoApiProfFetchStorageRootFn.profileRunner:
        result = api.fetchStorageRoot(a, b)

  profApi.finish =
    proc(a: AristoTxRef; b = false) =
      AristoApiProfFinishFn.profileRunner:
        api.finish(a, b)

  profApi.hasPathAccount =
    proc(a: AristoTxRef; b: Hash32): auto =
      AristoApiProfHasPathAccountFn.profileRunner:
        result = api.hasPathAccount(a, b)

  profApi.hasPathStorage =
    proc(a: AristoTxRef; b, c: Hash32): auto =
      AristoApiProfHasPathStorageFn.profileRunner:
        result = api.hasPathStorage(a, b, c)

  profApi.hasStorageData =
    proc(a: AristoTxRef; b: Hash32): auto =
      AristoApiProfHasStorageDataFn.profileRunner:
        result = api.hasStorageData(a, b)

  profApi.mergeAccountRecord =
    proc(a: AristoTxRef; b: Hash32; c: AristoAccount): auto =
      AristoApiProfMergeAccountRecordFn.profileRunner:
        result = api.mergeAccountRecord(a, b, c)

  profApi.mergeStorageData =
    proc(a: AristoTxRef; b, c: Hash32, d: UInt256): auto =
      AristoApiProfMergeStorageDataFn.profileRunner:
        result = api.mergeStorageData(a, b, c, d)

  profApi.partAccountTwig =
    proc(a: AristoTxRef; b: Hash32): auto =
      AristoApiProfPartAccountTwigFn.profileRunner:
        result = api.partAccountTwig(a, b)

  profApi.partStorageTwig =
    proc(a: AristoTxRef; b: Hash32; c: Hash32): auto =
      AristoApiProfPartStorageTwigFn.profileRunner:
        result = api.partStorageTwig(a, b, c)

  profApi.partUntwigPath =
    proc(a: openArray[seq[byte]]; b, c: Hash32): auto =
      AristoApiProfPartUntwigPathFn.profileRunner:
        result = api.partUntwigPath(a, b, c)

  profApi.partUntwigPathOk =
    proc(a: openArray[seq[byte]]; b, c: Hash32; d: Opt[seq[byte]]): auto =
      AristoApiProfPartUntwigPathOkFn.profileRunner:
        result = api.partUntwigPathOk(a, b, c, d)

  profApi.pathAsBlob =
    proc(a: PathID): auto =
      AristoApiProfPathAsBlobFn.profileRunner:
        result = api.pathAsBlob(a)

  profApi.persist =
    proc(a: AristoTxRef; b = 0u64): auto =
       AristoApiProfPersistFn.profileRunner:
        result = api.persist(a, b)

  profApi.dispose =
    proc(a: AristoTxRef) =
      AristoApiProfDisposeFn.profileRunner:
        api.dispose(a)

  profApi.txFrameBegin =
    proc(a: AristoTxRef): auto =
       AristoApiProfTxFrameBeginFn.profileRunner:
        result = api.txFrameBegin(a)

  profApi.baseTxFrame =
    proc(a: AristoTxRef): auto =
       AristoApiProfBaseTxFrameFn.profileRunner:
        result = api.baseTxFrame(a)

  let beDup = be.dup()
  if beDup.isNil:
    profApi.be = be

  else:
    beDup.getVtxFn =
      proc(a: RootedVertexID, flags: set[GetVtxFlag]): auto =
        AristoApiProfBeGetVtxFn.profileRunner:
          result = be.getVtxFn(a, flags)
    data.list[AristoApiProfBeGetVtxFn.ord].masked = true

    beDup.getKeyFn =
      proc(a: RootedVertexID): auto =
        AristoApiProfBeGetKeyFn.profileRunner:
          result = be.getKeyFn(a)
    data.list[AristoApiProfBeGetKeyFn.ord].masked = true

    beDup.getTuvFn =
      proc(): auto =
        AristoApiProfBeGetTuvFn.profileRunner:
          result = be.getTuvFn()
    data.list[AristoApiProfBeGetTuvFn.ord].masked = true

    beDup.getLstFn =
      proc(): auto =
        AristoApiProfBeGetLstFn.profileRunner:
          result = be.getLstFn()
    data.list[AristoApiProfBeGetLstFn.ord].masked = true

    beDup.putVtxFn =
      proc(a: PutHdlRef; b: RootedVertexID, c: VertexRef) =
        AristoApiProfBePutVtxFn.profileRunner:
          be.putVtxFn(a, b, c)
    data.list[AristoApiProfBePutVtxFn.ord].masked = true

    beDup.putTuvFn =
      proc(a: PutHdlRef; b: VertexID) =
        AristoApiProfBePutTuvFn.profileRunner:
          be.putTuvFn(a,b)
    data.list[AristoApiProfBePutTuvFn.ord].masked = true

    beDup.putLstFn =
      proc(a: PutHdlRef; b: SavedState) =
        AristoApiProfBePutLstFn.profileRunner:
          be.putLstFn(a,b)
    data.list[AristoApiProfBePutLstFn.ord].masked = true

    beDup.putEndFn =
      proc(a: PutHdlRef): auto =
        AristoApiProfBePutEndFn.profileRunner:
          result = be.putEndFn(a)
    data.list[AristoApiProfBePutEndFn.ord].masked = true

    profApi.be = beDup

  when AutoValidateApiHooks:
    profApi.validate

  profApi

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
