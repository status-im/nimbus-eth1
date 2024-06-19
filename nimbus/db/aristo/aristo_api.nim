# nimbus-eth1
# Copyright (c) 2024 Status Research & Development GmbH
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
  eth/[common, trie/nibbles],
  results,
  ./aristo_desc/desc_backend,
  ./aristo_init/memory_db,
  "."/[aristo_delete, aristo_desc, aristo_fetch, aristo_get, aristo_hashify,
       aristo_hike, aristo_init, aristo_merge, aristo_path, aristo_profile,
       aristo_serialise, aristo_tx]

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
  AristoApiCommitFn* =
    proc(tx: AristoTxRef;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Given a *top level* handle, this function accepts all database
      ## operations performed through this handle and merges it to the
      ## previous layer. The previous transaction is returned if there
      ## was any.

  AristoApiDeleteAccountPayloadFn* =
    proc(db: AristoDbRef;
         path: openArray[byte];
        ): Result[void,AristoError]
        {.noRaise.}
      ## Delete the account leaf entry addressed by the argument `path`. If
      ## this leaf entry referres to a storage tree, this one will be deleted
      ## as well.

  AristoApiDeleteGenericDataFn* =
    proc(db: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
        ): Result[bool,AristoError]
        {.noRaise.}
      ## Delete the leaf data entry addressed by the argument `path`.  The MPT
      ## sub-tree the leaf data entry is subsumed under is passed as argument
      ## `root` which must be greater than `VertexID(1)` and smaller than
      ## `LEAST_FREE_VID`.
      ##
      ## The return value is `true` if the argument `path` deleted was the last
      ## one and the tree does not exist anymore.

  AristoApiDeleteGenericTreeFn* =
    proc(db: AristoDbRef;
         root: VertexID;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Variant of `deleteGenericData()` for purging the whole MPT sub-tree.

  AristoApiDeleteStorageDataFn* =
    proc(db: AristoDbRef;
         path: openArray[byte];
         accPath: PathID;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For a given account argument `accPath`, this function deletes the
      ## argument `path` from the associated storage tree (if any, at all.) If
      ## the if the argument `path` deleted was the last one on the storage
      ## tree, account leaf referred to by `accPath` will be updated so that
      ## it will not refer to a storage tree anymore. In the latter case only
      ## the function will return `true`.

  AristoApiDeleteStorageTreeFn* =
    proc(db: AristoDbRef;
         accPath: PathID;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Variant of `deleteStorageData()` for purging the whole storage tree
      ## associated to the account argument `accPath`.

  AristoApiFetchLastSavedStateFn* =
    proc(db: AristoDbRef
        ): Result[SavedState,AristoError]
        {.noRaise.}
      ## The function returns the state of the last saved state. This is a
      ## Merkle hash tag for vertex with ID 1 and a bespoke `uint64` identifier
      ## (may be interpreted as block number.)

  AristoApiFetchAccountPayloadFn* =
    proc(db: AristoDbRef;
         path: openArray[byte];
        ): Result[AristoAccount,AristoError]
        {.noRaise.}
      ## Fetch an account record from the database indexed by `path`.

  AristoApiFetchAccountStateFn* =
    proc(db: AristoDbRef;
        ): Result[Hash256,AristoError]
        {.noRaise.}
      ## Fetch the Merkle hash of the account root.

  AristoApiFetchGenericDataFn* =
    proc(db: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
        ): Result[Blob,AristoError]
        {.noRaise.}
      ## For a generic sub-tree starting at `root`, fetch the data record
      ## indexed by `path`.

  AristoApiFetchStorageDataFn* =
    proc(db: AristoDbRef;
         path: openArray[byte];
         accPath: PathID;
        ): Result[Blob,AristoError]
        {.noRaise.}
      ## For a storage tree related to account `accPath`, fetch the data
      ## record from the database indexed by `path`.

  AristoApiFetchStorageStateFn* =
    proc(db: AristoDbRef;
         accPath: PathID;
        ): Result[Hash256,AristoError]
        {.noRaise.}
      ## Fetch the Merkle hash of the storage root related to `accPath`.

  AristoApiFindTxFn* =
    proc(db: AristoDbRef;
         vid: VertexID;
         key: HashKey;
        ): Result[int,AristoError]
        {.noRaise.}
      ## Find the transaction where the vertex with ID `vid` exists and has
      ## the Merkle hash key `key`. If there is no transaction available,
      ## search in the filter and then in the backend.
      ##
      ## If the above procedure succeeds, an integer indicating the transaction
      ## level is returned:
      ##
      ## * `0` -- top level, current layer
      ## * `1`,`2`,`..` -- some transaction level further down the stack
      ## * `-1` -- the filter between transaction stack and database backend
      ## * `-2` -- the databse backend
      ##
      ## A successful return code might be used for the `forkTx()` call for
      ## creating a forked descriptor that provides the pair `(vid,key)`.
      ##

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
    proc(db: AristoDbRef;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Destruct the non centre argument `db` descriptor (see comments on
      ## `reCentre()` for details.)
      ##
      ## A non centre descriptor should always be destructed after use (see
      ## also# comments on `fork()`.)

  AristoApiForkTxFn* =
    proc(db: AristoDbRef;
         backLevel: int;
        ): Result[AristoDbRef,AristoError]
        {.noRaise.}
    ## Fork a new descriptor obtained from parts of the argument database
    ## as described by arguments `db` and `backLevel`.
    ##
    ## If the argument `backLevel` is non-negative, the forked descriptor
    ## will provide the database view where the first `backLevel` transaction
    ## layers are stripped and the remaing layers are squashed into a single
    ## transaction.
    ##
    ## If `backLevel` is `-1`, a database descriptor with empty transaction
    ## layers will be provided where the `balancer` between database and
    ## transaction layers are kept in place.
    ##
    ## If `backLevel` is `-2`, a database descriptor with empty transaction
    ## layers will be provided without a `balancer`.
    ##
    ## The returned database descriptor will always have transaction level one.
    ## If there were no transactions that could be squashed, an empty
    ## transaction is added.
    ##
    ## Use `aristo_desc.forget()` to clean up this descriptor.

  AristoApiGetKeyRcFn* =
    proc(db: AristoDbRef;
         vid: VertexID;
        ): Result[HashKey,AristoError]
        {.noRaise.}
      ## Cascaded attempt to fetch a Merkle hash from the cache layers or
      ## the backend (if available.)

  AristoApiHashifyFn* =
    proc(db: AristoDbRef;
        ): Result[void,(VertexID,AristoError)]
        {.noRaise.}
      ## Add keys to the  `Patricia Trie` so that it becomes a `Merkle
      ## Patricia Tree`.

  AristoApiHasPathAccountFn* =
    proc(db: AristoDbRef;
         path: openArray[byte];
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For an account record indexed by `path` query whether this record
      ## exists on the database.

  AristoApiHasPathGenericFn* =
    proc(db: AristoDbRef;
         root: VertexID;
         path: openArray[byte];
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For a generic sub-tree starting at `root` and indexed by `path`,
      ## mquery whether this record exists on the database.

  AristoApiHasPathStorageFn* =
    proc(db: AristoDbRef;
         path: openArray[byte];
         accPath: PathID;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## For a storage tree related to account `accPath`, query whether the
      ## data record indexed by `path` exists on the database.

  AristoApiHikeUpFn* =
    proc(path: NibblesSeq;
         root: VertexID;
         db: AristoDbRef;
        ): Result[Hike,(VertexID,AristoError,Hike)]
        {.noRaise.}
      ## For the argument `path`, find and return the logest possible path
      ## in the argument database `db`.

  AristoApiIsTopFn* =
    proc(tx: AristoTxRef;
        ): bool
        {.noRaise.}
      ## Getter, returns `true` if the argument `tx` referes to the current
      ## top level transaction.

  AristoApiLevelFn* =
    proc(db: AristoDbRef;
        ): int
        {.noRaise.}
      ## Getter, non-negative nesting level (i.e. number of pending
      ## transactions)

  AristoApiNForkedFn* =
    proc(db: AristoDbRef;
        ): int
        {.noRaise.}
      ## Returns the number of non centre descriptors (see comments on
      ## `reCentre()` for details.) This function is a fast version of
      ## `db.forked.toSeq.len`.

  AristoApiMergeAccountPayloadFn* =
    proc(db: AristoDbRef;
         accPath: openArray[byte];
         accPayload: AristoAccount;
        ): Result[bool,AristoError]
        {.noRaise.}
      ## Merge the  key-value-pair argument `(accKey,accPayload)` as an account
      ## ledger value, i.e. the the sub-tree starting at `VertexID(1)`.
      ##
      ## The payload argument `accPayload` must have the `storageID` field
      ## either unset/invalid or referring to a existing vertex which will be
      ## assumed to be a storage tree.

  AristoApiMergeGenericDataFn* =
    proc( db: AristoDbRef;
          root: VertexID;
          path: openArray[byte];
          data: openArray[byte];
        ): Result[bool,AristoError]
        {.noRaise.}
      ## Variant of `mergeXXX()` for generic sub-trees, i.e. for arguments
      ## `root` greater than `VertexID(1)` and smaller than `LEAST_FREE_VID`.

  AristoApiMergeStorageDataFn* =
    proc(db: AristoDbRef;
         stoKey: openArray[byte];
         stoData: openArray[byte];
         accPath: PathID;
        ): Result[VertexID,AristoError]
        {.noRaise.}
      ## Merge the  key-value-pair argument `(stoKey,stoData)` as a storage
      ## value. This means, the root vertex will be derived from the `accPath`
      ## argument, the Patricia tree path for the storage tree is given by
      ## `stoKey` and the leaf value with the payload will be stored as a
      ## `PayloadRef` object of type `RawData`.
      ##
      ## If the storage tree does not exist yet it will be created and the
      ## payload leaf accessed by `accPath` will be updated with the storage
      ## tree vertex ID.

  AristoApiPathAsBlobFn* =
    proc(tag: PathID;
        ): Blob
        {.noRaise.}
      ## Converts the `tag` argument to a sequence of an even number of
      ## nibbles represented by a `Blob`. If the argument `tag` represents
      ## an odd number of nibbles, a zero nibble is appendend.
      ##
      ## This function is useful only if there is a tacit agreement that all
      ## paths used to index database leaf values can be represented as
      ## `Blob`, i.e. `PathID` type paths with an even number of nibbles.

  AristoApiPersistFn* =
    proc(db: AristoDbRef;
         nxtSid = 0u64;
         chunkedMpt = false;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Persistently store data onto backend database. If the system is
      ## running without a database backend, the function returns immediately
      ## with an error. The same happens if there is a pending transaction.
      ##
      ## The function merges all staged data from the top layer cache onto the
      ## backend stage area. After that, the top layer cache is cleared.
      ##
      ## Finally, the staged data are merged into the physical backend
      ## database and the staged data area is cleared.
      ##
      ## The argument `nxtSid` will be the ID for the next saved state record.
      ##
      ## Staging the top layer cache might fail with a partial MPT when it is
      ## set up from partial MPT chunks as it happens with `snap` sync
      ## processing. In this case, the `chunkedMpt` argument must be set
      ## `true` (see alse `fwdFilter()`.)

  AristoApiReCentreFn* =
    proc(db: AristoDbRef;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Re-focus the `db` argument descriptor so that it becomes the centre.
      ## Nothing is done if the `db` descriptor is the centre, already.
      ##
      ## With several descriptors accessing the same backend database there is
      ## a single one that has write permission for the backend (regardless
      ## whether there is a backend, at all.) The descriptor entity with write
      ## permission is called *the centre*.
      ##
      ## After invoking `reCentre()`, the argument database `db` can only be
      ## destructed by `finish()` which also destructs all other descriptors
      ## accessing the same backend database. Descriptors where `isCentre()`
      ## returns `false` must be single destructed with `forget()`.

  AristoApiRollbackFn* =
    proc(tx: AristoTxRef;
        ): Result[void,AristoError]
        {.noRaise.}
      ## Given a *top level* handle, this function discards all database
      ## operations performed for this transactio. The previous transaction
      ## is returned if there was any.

  AristoApiSerialiseFn* =
    proc(db: AristoDbRef;
         pyl: PayloadRef;
        ): Result[Blob,(VertexID,AristoError)]
        {.noRaise.}
      ## Encode the data payload of the argument `pyl` as RLP `Blob` if
      ## it is of account type, otherwise pass the data as is.

  AristoApiTxBeginFn* =
    proc(db: AristoDbRef
        ): Result[AristoTxRef,AristoError]
        {.noRaise.}
      ## Starts a new transaction.
      ##
      ## Example:
      ## ::
      ##   proc doSomething(db: AristoDbRef) =
      ##     let tx = db.begin
      ##     defer: tx.rollback()
      ##     ... continue using db ...
      ##     tx.commit()

  AristoApiTxTopFn* =
    proc(db: AristoDbRef;
        ): Result[AristoTxRef,AristoError]
        {.noRaise.}
      ## Getter, returns top level transaction if there is any.

  AristoApiRef* = ref AristoApiObj
  AristoApiObj* = object of RootObj
    ## Useful set of `Aristo` fuctions that can be filtered, stacked etc.
    commit*: AristoApiCommitFn

    deleteAccountPayload*: AristoApiDeleteAccountPayloadFn
    deleteGenericData*: AristoApiDeleteGenericDataFn
    deleteGenericTree*: AristoApiDeleteGenericTreeFn
    deleteStorageData*: AristoApiDeleteStorageDataFn
    deleteStorageTree*: AristoApiDeleteStorageTreeFn

    fetchLastSavedState*: AristoApiFetchLastSavedStateFn

    fetchAccountPayload*: AristoApiFetchAccountPayloadFn
    fetchAccountState*: AristoApiFetchAccountStateFn
    fetchGenericData*: AristoApiFetchGenericDataFn
    fetchStorageData*: AristoApiFetchStorageDataFn
    fetchStorageState*: AristoApiFetchStorageStateFn

    findTx*: AristoApiFindTxFn
    finish*: AristoApiFinishFn
    forget*: AristoApiForgetFn
    forkTx*: AristoApiForkTxFn
    getKeyRc*: AristoApiGetKeyRcFn
    hashify*: AristoApiHashifyFn

    hasPathAccount*: AristoApiHasPathAccountFn
    hasPathGeneric*: AristoApiHasPathGenericFn
    hasPathStorage*: AristoApiHasPathStorageFn

    hikeUp*: AristoApiHikeUpFn
    isTop*: AristoApiIsTopFn
    level*: AristoApiLevelFn
    nForked*: AristoApiNForkedFn

    mergeAccountPayload*: AristoApiMergeAccountPayloadFn
    mergeGenericData*: AristoApiMergeGenericDataFn
    mergeStorageData*: AristoApiMergeStorageDataFn

    pathAsBlob*: AristoApiPathAsBlobFn
    persist*: AristoApiPersistFn
    reCentre*: AristoApiReCentreFn
    rollback*: AristoApiRollbackFn
    serialise*: AristoApiSerialiseFn
    txBegin*: AristoApiTxBeginFn
    txTop*: AristoApiTxTopFn


  AristoApiProfNames* = enum
    ## Index/name mapping for profile slots
    AristoApiProfTotal                  = "total"
    AristoApiProfCommitFn               = "commit"

    AristoApiProfDeleteAccountPayloadFn = "deleteAccountPayload"
    AristoApiProfDeleteGenericDataFn    = "deleteGnericData"
    AristoApiProfDeleteGenericTreeFn    = "deleteGnericTree"
    AristoApiProfDeleteStorageDataFn    = "deleteStorageData"
    AristoApiProfDeleteStorageTreeFn    = "deleteStorageTree"

    AristoApiProfFetchLastSavedStateFn  = "fetchLastSavedState"

    AristoApiProfFetchAccountPayloadFn  = "fetchAccountPayload"
    AristoApiProfFetchAccountStateFn    = "fetchAccountState"
    AristoApiProfFetchGenericDataFn     = "fetchGenericData"
    AristoApiProfFetchStorageDataFn     = "fetchStorageData"
    AristoApiProfFetchStorageStateFn    = "fetchStorageState"

    AristoApiProfFindTxFn               = "findTx"
    AristoApiProfFinishFn               = "finish"
    AristoApiProfForgetFn               = "forget"
    AristoApiProfForkTxFn               = "forkTx"
    AristoApiProfGetKeyRcFn             = "getKeyRc"
    AristoApiProfHashifyFn              = "hashify"

    AristoApiProfHasPathAccountFn       = "hasPathAccount"
    AristoApiProfHasPathGenericFn       = "hasPathGeneric"
    AristoApiProfHasPathStorageFn       = "hasPathStorage"

    AristoApiProfHikeUpFn               = "hikeUp"
    AristoApiProfIsTopFn                = "isTop"
    AristoApiProfLevelFn                = "level"
    AristoApiProfNForkedFn              = "nForked"

    AristoApiProfMergeAccountPayloadFn  = "mergeAccountPayload"
    AristoApiProfMergeGenericDataFn     = "mergeGenericData"
    AristoApiProfMergeStorageDataFn     = "mergeStorageData"

    AristoApiProfPathAsBlobFn           = "pathAsBlob"
    AristoApiProfPersistFn              = "persist"
    AristoApiProfReCentreFn             = "reCentre"
    AristoApiProfRollbackFn             = "rollback"
    AristoApiProfSerialiseFn            = "serialise"
    AristoApiProfTxBeginFn              = "txBegin"
    AristoApiProfTxTopFn                = "txTop"

    AristoApiProfBeGetVtxFn             = "be/getVtx"
    AristoApiProfBeGetKeyFn             = "be/getKey"
    AristoApiProfBeGetTuvFn             = "be/getTuv"
    AristoApiProfBeGetLstFn             = "be/getLst"
    AristoApiProfBePutVtxFn             = "be/putVtx"
    AristoApiProfBePutKeyFn             = "be/putKey"
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
  proc validate(api: AristoApiObj|AristoApiRef) =
    doAssert not api.commit.isNil

    doAssert not api.deleteAccountPayload.isNil
    doAssert not api.deleteGenericData.isNil
    doAssert not api.deleteGenericTree.isNil
    doAssert not api.deleteStorageData.isNil
    doAssert not api.deleteStorageTree.isNil

    doAssert not api.fetchLastSavedState.isNil

    doAssert not api.fetchAccountPayload.isNil
    doAssert not api.fetchAccountState.isNil
    doAssert not api.fetchGenericData.isNil
    doAssert not api.fetchStorageData.isNil
    doAssert not api.fetchStorageState.isNil

    doAssert not api.findTx.isNil
    doAssert not api.finish.isNil
    doAssert not api.forget.isNil
    doAssert not api.forkTx.isNil
    doAssert not api.getKeyRc.isNil
    doAssert not api.hashify.isNil

    doAssert not api.hasPathAccount.isNil
    doAssert not api.hasPathGeneric.isNil
    doAssert not api.hasPathStorage.isNil

    doAssert not api.hikeUp.isNil
    doAssert not api.isTop.isNil
    doAssert not api.level.isNil
    doAssert not api.nForked.isNil

    doAssert not api.mergeAccountPayload.isNil
    doAssert not api.mergeGenericData.isNil
    doAssert not api.mergeStorageData.isNil

    doAssert not api.pathAsBlob.isNil
    doAssert not api.persist.isNil
    doAssert not api.reCentre.isNil
    doAssert not api.rollback.isNil
    doAssert not api.serialise.isNil
    doAssert not api.txBegin.isNil
    doAssert not api.txTop.isNil

  proc validate(prf: AristoApiProfRef) =
    prf.AristoApiRef.validate
    doAssert not prf.data.isNil

proc dup(be: BackendRef): BackendRef =
  case be.kind:
  of BackendMemory:
    return MemBackendRef(be).dup

  of BackendRocksDB, BackendRdbHosting:
    when AristoPersistentBackendOk:
      return RdbBackendRef(be).dup

  of BackendVoid:
    discard

# ------------------------------------------------------------------------------
# Public API constuctors
# ------------------------------------------------------------------------------

func init*(api: var AristoApiObj) =
  ## Initialise an `api` argument descriptor
  ##
  when AutoValidateApiHooks:
    api.reset
  api.commit = commit

  api.deleteAccountPayload = deleteAccountPayload
  api.deleteGenericData = deleteGenericData
  api.deleteGenericTree = deleteGenericTree
  api.deleteStorageData = deleteStorageData
  api.deleteStorageTree = deleteStorageTree

  api.fetchLastSavedState = fetchLastSavedState

  api.fetchAccountPayload = fetchAccountPayload
  api.fetchAccountState = fetchAccountState
  api.fetchGenericData = fetchGenericData
  api.fetchStorageData = fetchStorageData
  api.fetchStorageState = fetchStorageState

  api.findTx = findTx
  api.finish = finish
  api.forget = forget
  api.forkTx = forkTx
  api.getKeyRc = getKeyRc
  api.hashify = hashify

  api.hasPathAccount = hasPathAccount
  api.hasPathGeneric = hasPathGeneric
  api.hasPathStorage = hasPathStorage

  api.hikeUp = hikeUp
  api.isTop = isTop
  api.level = level
  api.nForked = nForked

  api.mergeAccountPayload = mergeAccountPayload
  api.mergeGenericData = mergeGenericData
  api.mergeStorageData = mergeStorageData

  api.pathAsBlob = pathAsBlob
  api.persist = persist
  api.reCentre = reCentre
  api.rollback = rollback
  api.serialise = serialise
  api.txBegin = txBegin
  api.txTop = txTop
  when AutoValidateApiHooks:
    api.validate

func init*(T: type AristoApiRef): T =
  new result
  result[].init()

func dup*(api: AristoApiRef): AristoApiRef =
  result = AristoApiRef(
    commit:               api.commit,

    deleteAccountPayload: api.deleteAccountPayload,
    deleteGenericData:    api.deleteGenericData,
    deleteGenericTree:    api.deleteGenericTree,
    deleteStorageData:    api.deleteStorageData,
    deleteStorageTree:    api.deleteStorageTree,

    fetchLastSavedState:  api.fetchLastSavedState,
    fetchAccountPayload:  api.fetchAccountPayload,
    fetchAccountState:    api.fetchAccountState,
    fetchGenericData:     api.fetchGenericData,
    fetchStorageData:     api.fetchStorageData,
    fetchStorageState:    api.fetchStorageState,

    findTx:               api.findTx,
    finish:               api.finish,
    forget:               api.forget,
    forkTx:               api.forkTx,
    getKeyRc:             api.getKeyRc,
    hashify:              api.hashify,

    hasPathAccount:       api.hasPathAccount,
    hasPathGeneric:       api.hasPathGeneric,
    hasPathStorage:       api.hasPathStorage,

    hikeUp:               api.hikeUp,
    isTop:                api.isTop,
    level:                api.level,
    nForked:              api.nForked,

    mergeAccountPayload:  api.mergeAccountPayload,
    mergeGenericData:     api.mergeGenericData,
    mergeStorageData:     api.mergeStorageData,

    pathAsBlob:           api.pathAsBlob,
    persist:              api.persist,
    reCentre:             api.reCentre,
    rollback:             api.rollback,
    serialise:            api.serialise,
    txBegin:              api.txBegin,
    txTop:                api.txTop)
  when AutoValidateApiHooks:
    api.validate

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
  ## `.backend` field of the `AristoDbRef` descriptor.
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

  profApi.commit =
    proc(a: AristoTxRef): auto =
      AristoApiProfCommitFn.profileRunner:
        result = api.commit(a)

  profApi.deleteAccountPayload =
    proc(a: AristoDbRef; b: openArray[byte]): auto =
      AristoApiProfDeleteAccountPayloadFn.profileRunner:
        result = api.deleteAccountPayload(a, b)

  profApi.deleteGenericData =
    proc(a: AristoDbRef; b: VertexID; c: openArray[byte]): auto =
      AristoApiProfDeleteGenericDataFn.profileRunner:
        result = api.deleteGenericData(a, b, c)

  profApi.deleteGenericTree =
    proc(a: AristoDbRef; b: VertexID): auto =
      AristoApiProfDeleteGenericTreeFn.profileRunner:
        result = api.deleteGenericTree(a, b)

  profApi.deleteStorageData =
    proc(a: AristoDbRef; b: openArray[byte]; c: PathID): auto =
      AristoApiProfDeleteStorageDataFn.profileRunner:
        result = api.deleteStorageData(a, b, c)

  profApi.deleteStorageTree =
    proc(a: AristoDbRef; b: PathID): auto =
      AristoApiProfDeleteStorageTreeFn.profileRunner:
        result = api.deleteStorageTree(a, b)

  profApi.fetchLastSavedState =
    proc(a: AristoDbRef): auto =
      AristoApiProfFetchLastSavedStateFn.profileRunner:
        result = api.fetchLastSavedState(a)

  profApi.fetchAccountPayload =
    proc(a: AristoDbRef; b: openArray[byte]): auto =
      AristoApiProfFetchAccountPayloadFn.profileRunner:
        result = api.fetchAccountPayload(a, b)

  profApi.fetchAccountState =
    proc(a: AristoDbRef): auto =
      AristoApiProfFetchAccountStateFn.profileRunner:
        result = api.fetchAccountState(a)

  profApi.fetchGenericData =
    proc(a: AristoDbRef; b: VertexID; c: openArray[byte]): auto =
      AristoApiProfFetchGenericDataFn.profileRunner:
        result = api.fetchGenericData(a, b, c)

  profApi.fetchStorageData =
    proc(a: AristoDbRef; b: openArray[byte]; c: PathID;): auto =
      AristoApiProfFetchStorageDataFn.profileRunner:
        result = api.fetchStorageData(a, b, c)

  profApi.fetchStorageState =
    proc(a: AristoDbRef; b: PathID;): auto =
      AristoApiProfFetchStorageStateFn.profileRunner:
        result = api.fetchStorageState(a, b)

  profApi.findTx =
    proc(a: AristoDbRef; b: VertexID; c: HashKey): auto =
      AristoApiProfFindTxFn.profileRunner:
        result = api.findTx(a, b, c)

  profApi.finish =
    proc(a: AristoDbRef; b = false) =
      AristoApiProfFinishFn.profileRunner:
        api.finish(a, b)

  profApi.forget =
    proc(a: AristoDbRef): auto =
      AristoApiProfForgetFn.profileRunner:
        result = api.forget(a)

  profApi.forkTx =
    proc(a: AristoDbRef; b: int; c = false): auto =
      AristoApiProfForkTxFn.profileRunner:
        result = api.forkTx(a, b, c)

  profApi.getKeyRc =
    proc(a: AristoDbRef; b: VertexID): auto =
      AristoApiProfGetKeyRcFn.profileRunner:
        result = api.getKeyRc(a, b)

  profApi.hashify =
    proc(a: AristoDbRef): auto =
      AristoApiProfHashifyFn.profileRunner:
        result = api.hashify(a)

  profApi.hasPathAccount =
    proc(a: AristoDbRef; b: openArray[byte]): auto =
      AristoApiProfHasPathAccountFn.profileRunner:
        result = api.hasPathAccount(a, b)

  profApi.hasPathGeneric =
    proc(a: AristoDbRef; b: VertexID; c: openArray[byte]): auto =
      AristoApiProfHasPathGenericFn.profileRunner:
        result = api.hasPathGeneric(a, b, c)

  profApi.hasPathStorage =
    proc(a: AristoDbRef; b: openArray[byte]; c: PathID;): auto =
      AristoApiProfHasPathStorageFn.profileRunner:
        result = api.hasPathStorage(a, b, c)

  profApi.hikeUp =
    proc(a: NibblesSeq; b: VertexID; c: AristoDbRef): auto =
      AristoApiProfHikeUpFn.profileRunner:
        result = api.hikeUp(a, b, c)

  profApi.isTop =
    proc(a: AristoTxRef): auto =
      AristoApiProfIsTopFn.profileRunner:
        result = api.isTop(a)

  profApi.level =
    proc(a: AristoDbRef): auto =
       AristoApiProfLevelFn.profileRunner:
         result = api.level(a)

  profApi.nForked =
    proc(a: AristoDbRef): auto =
      AristoApiProfNForkedFn.profileRunner:
         result = api.nForked(a)

  profApi.mergeAccountPayload =
    proc(a: AristoDbRef; b, c: openArray[byte]): auto =
      AristoApiProfMergeAccountPayloadFn.profileRunner:
        result = api.mergeAccountPayload(a, b, c)

  profApi.mergeGenericData =
    proc(a: AristoDbRef; b: VertexID, c, d: openArray[byte]): auto =
      AristoApiProfMergeGenericDataFn.profileRunner:
        result = api.mergeGenericData(a, b, c, d)

  profApi.mergeStorageData =
    proc(a: AristoDbRef; b, c: openArray[byte]; d: PathID): auto =
      AristoApiProfMergeStorageDataFn.profileRunner:
        result = api.mergeStorageData(a, b, c, d)

  profApi.pathAsBlob =
    proc(a: PathID): auto =
      AristoApiProfPathAsBlobFn.profileRunner:
        result = api.pathAsBlob(a)

  profApi.persist =
    proc(a: AristoDbRef; b = 0u64; c = false): auto =
       AristoApiProfPersistFn.profileRunner:
        result = api.persist(a, b, c)

  profApi.reCentre =
    proc(a: AristoDbRef): auto =
      AristoApiProfReCentreFn.profileRunner:
        result = api.reCentre(a)

  profApi.rollback =
    proc(a: AristoTxRef): auto =
      AristoApiProfRollbackFn.profileRunner:
        result = api.rollback(a)

  profApi.serialise =
    proc(a: AristoDbRef; b: PayloadRef): auto =
      AristoApiProfSerialiseFn.profileRunner:
        result = api.serialise(a, b)

  profApi.txBegin =
    proc(a: AristoDbRef): auto =
       AristoApiProfTxBeginFn.profileRunner:
        result = api.txBegin(a)

  profApi.txTop =
    proc(a: AristoDbRef): auto =
      AristoApiProfTxTopFn.profileRunner:
        result = api.txTop(a)

  let beDup = be.dup()
  if beDup.isNil:
    profApi.be = be

  else:
    beDup.getVtxFn =
      proc(a: VertexID): auto =
        AristoApiProfBeGetVtxFn.profileRunner:
          result = be.getVtxFn(a)
    data.list[AristoApiProfBeGetVtxFn.ord].masked = true

    beDup.getKeyFn =
      proc(a: VertexID): auto =
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
      proc(a: PutHdlRef; b: openArray[(VertexID,VertexRef)]) =
        AristoApiProfBePutVtxFn.profileRunner:
          be.putVtxFn(a,b)
    data.list[AristoApiProfBePutVtxFn.ord].masked = true

    beDup.putKeyFn =
      proc(a: PutHdlRef; b: openArray[(VertexID,HashKey)]) =
        AristoApiProfBePutKeyFn.profileRunner:
          be.putKeyFn(a,b)
    data.list[AristoApiProfBePutKeyFn.ord].masked = true

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
