# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strutils, typetraits],
  chronicles,
  eth/common,
  stew/byteutils,
  ../../../aristo,
  ../../../aristo/aristo_desc,
  ../../base,
  ../../base/base_desc,
  ./common_desc

type
  AristoBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    api*: AristoApiRef           ## Api functions can be re-directed
    ctx*: AristoCoreDbCtxRef     ## Currently active context

  AristoCoreDbCtxRef* = ref object of CoreDbCtxRef
    base: AristoBaseRef          ## Local base descriptor
    mpt*: AristoDbRef            ## Aristo MPT database

  AristoCoreDbAccRef = ref object of CoreDbAccRef
    base: AristoBaseRef          ## Local base descriptor

  AristoCoreDbMptRef = ref object of CoreDbMptRef
    base: AristoBaseRef          ## Local base descriptor
    mptRoot: VertexID            ## State root, may be zero unless account
    accPath: PathID              ## Needed for storage tree/columns
    address: EthAddress          ## For storage tree debugging

  AristoColRef* = ref object of CoreDbColRef
    ## Vertex ID wrapper, optionally with *MPT* context
    base: AristoBaseRef
    case colType: CoreDbColType  ## Current column type
    of CtStorage:
      stoRoot: VertexID          ## State root, may be zero if unknown
      stoAddr: EthAddress        ## Associated storage account address
    else:
      reset: bool                ## Internal delete request

  AristoCoreDbMptBE* = ref object of CoreDbMptBackendRef
    adb*: AristoDbRef

  AristoCoreDbAccBE* = ref object of CoreDbAccBackendRef
    adb*: AristoDbRef

const
  VoidVID = VertexID(0)
  # StorageVID = VertexID(CtStorage) -- currently unused
  AccountsVID = VertexID(CtAccounts)
  GenericVID = VertexID(CtGeneric)

logScope:
  topics = "aristo-hdl"

static:
  doAssert CtStorage.ord == 0
  doAssert CtAccounts.ord == 1
  doAssert low(CoreDbColType).ord == 0
  doAssert high(CoreDbColType).ord < LEAST_FREE_VID

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func isValid(col: CoreDbColRef): bool =
  not col.isNil and col.ready

func to(col: CoreDbColRef; T: type VertexID): T =
  if col.isValid:
    let col = AristoColRef(col)
    if col.colType == CtStorage:
      return col.stoRoot
    return VertexID(col.colType)

func to(eAddr: EthAddress; T: type PathID): T =
  HashKey.fromBytes(eAddr.keccakHash.data).value.to(T)

func resetCol(colType: CoreDbColType): bool =
  ## Check whether to reset some non-dynamic column when instantiating. It
  ## emulates the behaviour of a new empty MPT on the legacy database.
  colType == CtGeneric or
    (high(CoreDbColType) < colType and colType.ord < LEAST_FREE_VID)

# -------------------------------

func toCoreDbAccount(
    cAcc: AristoCoreDbAccRef;
    acc: AristoAccount;
    address: EthAddress;
      ): CoreDbAccount =
  let db = cAcc.base.parent
  result = CoreDbAccount(
    address:  address,
    nonce:    acc.nonce,
    balance:  acc.balance,
    codeHash: acc.codeHash)
  if acc.storageID.isValid:
    result.storage = db.bless AristoColRef(
      base:    cAcc.base,
      colType: CtStorage,
      stoRoot: acc.storageID,
      stoAddr: address)

func toPayloadRef(acc: CoreDbAccount): PayloadRef =
  PayloadRef(
    pType:       AccountData,
    account: AristoAccount(
      nonce:     acc.nonce,
      balance:   acc.balance,
      storageID: acc.storage.to(VertexID),
      codeHash:  acc.codeHash))

# -------------------------------

func toError(
    e: AristoError;
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    aErr:     e))

# Forward declaration, see below in public section
func toError*(
    e: (VertexID,AristoError);
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef


func toRc[T](
    rc: Result[T,(VertexID,AristoError)];
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err rc.error.toError(base, info, error)


func toRc[T](
    rc: Result[T,AristoError];
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err((VoidVID,rc.error).toError(base, info, error))


func toVoidRc[T](
    rc: Result[T,(VertexID,AristoError)];
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err rc.error.toError(base, info, error)

# ------------------------------------------------------------------------------
# Private `MPT` call back functions
# ------------------------------------------------------------------------------
proc mptMethods(): CoreDbMptFns =
  # These templates are a hack to remove a closure environment that was using
  # hundreds of mb of memory to have this syntactic convenience
  # TODO remove methods / abstraction entirely - it is no longer needed
  template base: untyped = cMpt.base
  template db: untyped = base.parent   # Ditto
  template api: untyped = base.api     # Ditto
  template mpt: untyped = base.ctx.mpt # Ditto

  proc mptBackend(cMpt: AristoCoreDbMptRef): CoreDbMptBackendRef =
    db.bless AristoCoreDbMptBE(adb: mpt)

  proc mptColFn(cMpt: AristoCoreDbMptRef): CoreDbColRef =
    if cMpt.mptRoot.distinctBase < LEAST_FREE_VID:
      return db.bless(AristoColRef(
        base:    base,
        colType: CoreDbColType(cMpt.mptRoot)))

    assert cMpt.accPath.isValid # debug mode only
    if cMpt.mptRoot.isValid:
      # The mpt might have become empty
      let
        key = cMpt.address.keccakHash.data
        acc = api.fetchAccountPayload(mpt, key).valueOr:
          raiseAssert "mptColFn(): " & $error

      # Update by accounts data
      cMpt.mptRoot = acc.storageID

    db.bless AristoColRef(
      base:    base,
      colType: CtStorage,
      stoRoot: cMpt.mptRoot,
      stoAddr: cMpt.address)

  proc mptFetch(cMpt: AristoCoreDbMptRef, key: openArray[byte]): CoreDbRc[Blob] =
    const info = "fetchFn()"

    let rc = block:
      if cMpt.accPath.isValid:
        api.fetchStorageData(mpt, key, cMpt.accPath)
      elif cMpt.mptRoot.isValid:
        api.fetchGenericData(mpt, cMpt.mptRoot, key)
      else:
        # Some pathological behaviour observed with storage column due to lazy
        # update. The `fetchXxxPayload()` does not now about this and would
        # complain an error different from `FetchPathNotFound`.
        return err(MptRootMissing.toError(base, info, MptNotFound))

    # let rc = api.fetchPayload(mpt, rootVID, key)
    if rc.isOk:
      ok rc.value
    elif rc.error != FetchPathNotFound:
      err(rc.error.toError(base, info))
    else:
      err(rc.error.toError(base, info, MptNotFound))

  proc mptMerge(cMpt: AristoCoreDbMptRef, k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
    const info = "mergeFn()"

    if cMpt.accPath.isValid:
      let rc = api.mergeStorageData(mpt, k, v, cMpt.accPath)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      if rc.value.isValid:
        cMpt.mptRoot = rc.value
    else:
      let rc = api.mergeGenericData(mpt, cMpt.mptRoot, k, v)
      if rc.isErr:
        return err(rc.error.toError(base, info))

    ok()

  proc mptDelete(cMpt: AristoCoreDbMptRef, key: openArray[byte]): CoreDbRc[void] =
    const info = "deleteFn()"

    let rc = block:
      if cMpt.accPath.isValid:
        api.deleteStorageData(mpt, key, cMpt.accPath)
      else:
        api.deleteGenericData(mpt, cMpt.mptRoot, key)

    if rc.isErr:
      if rc.error == DelPathNotFound:
        return err(rc.error.toError(base, info, MptNotFound))
      if rc.error == DelStoRootMissing:
        # This is insane but legit. A storage column was announced for an
        # account but no data have been added, yet.
        return ok()
      return err(rc.error.toError(base, info))

    if rc.value:
      # Column has become empty
      cMpt.mptRoot = VoidVID

    ok()

  proc mptHasPath(cMpt: AristoCoreDbMptRef, key: openArray[byte]): CoreDbRc[bool] =
    const info = "hasPathFn()"

    let rc = block:
      if cMpt.accPath.isValid:
        api.hasPathStorage(mpt, key, cMpt.accPath)
      else:
        api.hasPathGeneric(mpt, cMpt.mptRoot, key)

    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok(rc.value)

  ## Generic columns database handlers
  CoreDbMptFns(
    backendFn: proc(cMpt: CoreDbMptRef): CoreDbMptBackendRef =
      mptBackend(AristoCoreDbMptRef(cMpt)),

    fetchFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[Blob] =
      mptFetch(AristoCoreDbMptRef(cMpt), k),

    deleteFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[void] =
      mptDelete(AristoCoreDbMptRef(cMpt), k),

    mergeFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      mptMerge(AristoCoreDbMptRef(cMpt), k, v),

    hasPathFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[bool] =
      mptHasPath(AristoCoreDbMptRef(cMpt), k),

    getColFn: proc(cMpt: CoreDbMptRef): CoreDbColRef =
      mptColFn(AristoCoreDbMptRef(cMpt)))

# ------------------------------------------------------------------------------
# Private account call back functions
# ------------------------------------------------------------------------------

proc accMethods(): CoreDbAccFns =
  ## Account columns database handlers
  template base: untyped = cAcc.base
  template db: untyped = base.parent
  template api: untyped = base.api
  template mpt: untyped = base.ctx.mpt

  proc accBackend(cAcc: AristoCoreDbAccRef): CoreDbAccBackendRef =
    db.bless AristoCoreDbAccBE(adb: mpt)

  proc accFetch(cAcc: AristoCoreDbAccRef; eAddr: EthAddress): CoreDbRc[CoreDbAccount] =
    const info = "acc/fetchFn()"

    let acc = api.fetchAccountPayload(mpt, eAddr.keccakHash.data).valueOr:
      if error != FetchPathNotFound:
        return err(error.toError(base, info))
      return err(error.toError(base, info, AccNotFound))
    ok cAcc.toCoreDbAccount(acc, eAddr)

  proc accMerge(cAcc: AristoCoreDbAccRef, account: CoreDbAccount): CoreDbRc[void] =
    const info = "acc/mergeFn()"

    let
      key = account.address.keccakHash.data
      val = account.toPayloadRef().account
    api.mergeAccountPayload(mpt, key, val).isOkOr:
      return err(error.toError(base, info))
    ok()

  proc accDelete(cAcc: AristoCoreDbAccRef; eAddr: EthAddress): CoreDbRc[void] =
    const info = "acc/deleteFn()"

    api.deleteAccountPayload(mpt, eAddr.keccakHash.data).isOkOr:
      if error == DelPathNotFound:
        # TODO: Would it be conseqient to just return `ok()` here?
        return err(error.toError(base, info, AccNotFound))
      return err(error.toError(base, info))
    ok()

  proc accClearStorage(cAcc: AristoCoreDbAccRef; eAddr: EthAddress): CoreDbRc[void] =
    const info = "acc/clearStoFn()"

    api.deleteStorageTree(mpt, eAddr.to(PathID)).isOkOr:
      if error notin {DelStoRootMissing,DelStoAccMissing}:
        return err(error.toError(base, info))
    ok()

  proc accHasPath(cAcc: AristoCoreDbAccRef; eAddr: EthAddress): CoreDbRc[bool] =
    const info = "hasPathFn()"

    let yn = api.hasPathAccount(mpt, eAddr.keccakHash.data).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc accState(cAcc: AristoCoreDbAccRef, updateOk: bool): CoreDbRc[Hash256] =
    const info = "accState()"

    let rc = api.fetchAccountState(mpt)
    if rc.isOk:
      return ok(rc.value)
    elif not updateOk and rc.error != GetKeyUpdateNeeded:
      return err(rc.error.toError(base, info))

    # FIXME: `hashify()` should probably throw an assert on failure
    ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

    let state = api.fetchAccountState(mpt).valueOr:
      raiseAssert info & ": " & $error
    ok(state)


  proc slotFetch(cAcc: AristoCoreDbAccRef; eAddr: EthAddress; key: openArray[byte]): CoreDbRc[Blob] =
    const info = "acc/stoFetchFn()"

    let data = api.fetchStorageData(mpt, key, eAddr.to(PathID)).valueOr:
      if error != FetchPathNotFound:
        return err(error.toError(base, info))
      return err(error.toError(base, info, StoNotFound))
    ok(data)

  proc slotDelete(cAcc: AristoCoreDbAccRef; eAddr: EthAddress; key: openArray[byte]): CoreDbRc[void] =
    const info = "acc/stoDeleteFn()"

    api.deleteStorageData(mpt, key, eAddr.to(PathID)).isOkOr:
      if error == DelPathNotFound:
        return err(error.toError(base, info, StoNotFound))
      if error == DelStoRootMissing:
        # This is insane but legit. A storage column was announced for an
        # account but no data have been added, yet.
        return ok()
      return err(error.toError(base, info))
    ok()

  proc slotHasPath(cAcc: AristoCoreDbAccRef; eAddr: EthAddress; key: openArray[byte]): CoreDbRc[bool] =
    const info = "acc/stoHasPathFn()"

    let yn = api.hasPathStorage(mpt, key, eAddr.to(PathID)).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc slotMerge(cAcc: AristoCoreDbAccRef; eAddr: EthAddress; key, val: openArray[byte]): CoreDbRc[void] =
    const info = "acc/stoMergeFn()"

    api.mergeStorageData(mpt, key, val, eAddr.to(PathID)).isOkOr:
        return err(error.toError(base, info))
    ok()

  proc slotState(cAcc: AristoCoreDbAccRef; eAddr: EthAddress; updateOk: bool): CoreDbRc[Hash256] =
    const info = "acc/stoStateFn()"

    let rc = api.fetchStorageState(mpt, eAddr.to(PathID))
    if rc.isOk:
      return ok(rc.value)
    elif not updateOk and rc.error != GetKeyUpdateNeeded:
      return err(rc.error.toError(base, info))

    # FIXME: `hashify()` should probably throw an assert on failure
    ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

    let state = api.fetchStorageState(mpt, eAddr.to(PathID)).valueOr:
      return err(error.toError(base, info))
    ok(state)


  CoreDbAccFns(
    backendFn: proc(cAcc: CoreDbAccRef): CoreDbAccBackendRef =
      accBackend(AristoCoreDbAccRef(cAcc)),

    fetchFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress): CoreDbRc[CoreDbAccount] =
      accFetch(AristoCoreDbAccRef(cAcc), eAddr),

    deleteFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress): CoreDbRc[void] =
      accDelete(AristoCoreDbAccRef(cAcc), eAddr),

    clearStorageFn: proc(cAcc: CoreDbAccRef; eAddr: EthAddress): CoreDbRc[void] =
      accClearStorage(AristoCoreDbAccRef(cAcc), eAddr),

    mergeFn: proc(cAcc: CoreDbAccRef, acc: CoreDbAccount): CoreDbRc[void] =
      accMerge(AristoCoreDbAccRef(cAcc), acc),

    hasPathFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress): CoreDbRc[bool] =
      accHasPath(AristoCoreDbAccRef(cAcc), eAddr),

    stateFn: proc(cAcc: CoreDbAccRef, updateOk: bool): CoreDbRc[Hash256] =
      accState(AristoCoreDbAccRef(cAcc), updateOk),

    slotFetchFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress; k: openArray[byte]): CoreDbRc[Blob] =
      slotFetch(AristoCoreDbAccRef(cAcc), eAddr, k),

    slotDeleteFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress; k: openArray[byte]): CoreDbRc[void] =
      slotDelete(AristoCoreDbAccRef(cAcc), eAddr, k),

    slotHasPathFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress; k: openArray[byte]): CoreDbRc[bool] =
      slotHasPath(AristoCoreDbAccRef(cAcc), eAddr, k),

    slotMergeFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress; k,v: openArray[byte]): CoreDbRc[void] =
      slotMerge(AristoCoreDbAccRef(cAcc), eAddr, k, v),

    slotStateFn: proc(cAcc: CoreDbAccRef, eAddr: EthAddress; updateOk: bool): CoreDbRc[Hash256] =
      slotState(AristoCoreDbAccRef(cAcc), eAddr, updateOk))

# ------------------------------------------------------------------------------
# Private context call back functions
# ------------------------------------------------------------------------------

proc ctxMethods(cCtx: AristoCoreDbCtxRef): CoreDbCtxFns =
  template base: untyped = cCtx.base
  template db: untyped = base.parent
  template api: untyped = base.api
  template mpt: untyped = cCtx.mpt

  proc ctxNewCol(
      cCtx: AristoCoreDbCtxRef,
      colType: CoreDbColType;
      colState: Hash256;
      address: Opt[EthAddress];
        ): CoreDbRc[CoreDbColRef] =
    const info = "ctx/newColFn()"

    let col = AristoColRef(
      base:    base,
      colType: colType)

    if colType == CtStorage:
      if address.isNone:
        let error = aristo.UtilsAccPathMissing
        return err(error.toError(base, info, AccAddrMissing))
      col.stoAddr = address.unsafeGet

    if not colState.isValid:
      return ok(db.bless col)

    # Reset some non-dynamic col when instantiating. It emulates the behaviour
    # of a new empty MPT on the legacy database.
    col.reset = colType.resetCol()

    # Update hashes in order to verify the column state.
    ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

    # Assure that hash is available as state for the main/accounts column
    let rc = api.getKeyRc(mpt, VertexID colType)
    if rc.isErr:
      doAssert rc.error == GetKeyNotFound
    elif rc.value == colState.to(HashKey):
      return ok(db.bless col)
    err(aristo.GenericError.toError(base, info, RootNotFound))


  proc ctxGetMpt(cCtx: AristoCoreDbCtxRef, col: CoreDbColRef): CoreDbRc[CoreDbMptRef] =
    const
      info = "ctx/getMptFn()"
    let
      col = AristoColRef(col)
    var
      reset = false
      newMpt: AristoCoreDbMptRef
    if not col.isValid:
      reset = true
      newMpt = AristoCoreDbMptRef(
        mptRoot: GenericVID,
        accPath: VOID_PATH_ID)

    elif col.colType == CtStorage:
      newMpt = AristoCoreDbMptRef(
        mptRoot: col.stoRoot,
        accPath: col.stoAddr.to(PathID),
        address: col.stoAddr)
      if col.stoRoot.isValid:
        if col.stoRoot.distinctBase < LEAST_FREE_VID:
          let error = (col.stoRoot,MptRootUnacceptable)
          return err(error.toError(base, info, RootUnacceptable))
        # Verify path if there is a particular storge root VID
        let rc = api.hikeUp(newMpt.accPath.to(NibblesBuf), AccountsVID, mpt)
        if rc.isErr:
          return err(rc.error[1].toError(base, info, AccNotFound))
    else:
      reset = col.colType.resetCol()
      newMpt = AristoCoreDbMptRef(
        mptRoot: VertexID(col.colType),
        accPath: VOID_PATH_ID)

    # Reset column. This a emulates the behaviour of a new empty MPT on the
    # legacy database.
    if reset:
      let rc = api.deleteGenericTree(mpt, newMpt.mptRoot)
      if rc.isErr:
        return err(rc.error.toError(base, info, AutoFlushFailed))
      col.reset = false

    newMpt.base = base
    newMpt.methods = mptMethods()
    ok(db.bless newMpt)

  proc ctxGetAccounts(cCtx: AristoCoreDbCtxRef): CoreDbAccRef =
    let acc = AristoCoreDbAccRef(base: base)
    acc.methods = accMethods()
    db.bless acc

  proc ctxForget(cCtx: AristoCoreDbCtxRef) =
    api.forget(mpt).isOkOr:
      raiseAssert "forgetFn(): " & $error


  CoreDbCtxFns(
    newColFn: proc(
        cCtx: CoreDbCtxRef;
        col: CoreDbColType;
        colState: Hash256;
        address: Opt[EthAddress];
          ): CoreDbRc[CoreDbColRef] =
      ctxNewCol(AristoCoreDbCtxRef(cCtx), col, colState, address),

    getMptFn: proc(cCtx: CoreDbCtxRef, col: CoreDbColRef): CoreDbRc[CoreDbMptRef] =
      ctxGetMpt(AristoCoreDbCtxRef(cCtx), col),

    getAccountsFn: proc(cCtx: CoreDbCtxRef): CoreDbAccRef =
      ctxGetAccounts(AristoCoreDbCtxRef(cCtx)),

    forgetFn: proc(cCtx: CoreDbCtxRef) =
      ctxForget(AristoCoreDbCtxRef(cCtx)))

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

func toError*(
    e: (VertexID,AristoError);
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    vid:      e[0],
    aErr:     e[1]))

func toVoidRc*[T](
    rc: Result[T,AristoError];
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err((VoidVID,rc.error).toError(base, info, error))

proc getSavedState*(base: AristoBaseRef): Result[SavedState,void] =
  let be = base.ctx.mpt.backend
  if not be.isNil:
    let rc = base.api.fetchLastSavedState(base.ctx.mpt)
    if rc.isOk:
      return ok(rc.value)
  err()

# ---------------------

func to*(dsc: CoreDbMptRef, T: type AristoDbRef): T =
  AristoCoreDbMptRef(dsc).base.ctx.mpt

func to*(dsc: CoreDbAccRef, T: type AristoDbRef): T =
  AristoCoreDbAccRef(dsc).base.ctx.mpt

func to*(dsc: CoreDbMptRef, T: type AristoApiRef): T =
  AristoCoreDbMptRef(dsc).base.api

func to*(dsc: CoreDbAccRef, T: type AristoApiRef): T =
  AristoCoreDbAccRef(dsc).base.api

func rootID*(dsc: CoreDbMptRef): VertexID  =
  AristoCoreDbMptRef(dsc).mptRoot

func txTop*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.api.txTop(base.adb).toRc(base, info)

proc txBegin*(
    base: AristoBaseRef;
    info: static[string];
      ): AristoTxRef =
  let rc = base.api.txBegin(base.ctx.mpt)
  if rc.isErr:
    raiseAssert info & ": " & $rc.error
  rc.value

proc getLevel*(base: AristoBaseRef): int =
  base.api.level(base.ctx.mpt)

# ---------------------

proc colPrint*(
    base: AristoBaseRef;
    col: CoreDbColRef;
      ): string =
  if col.isValid:
    let
      col = AristoColRef(col)
      root = col.to(VertexID)
    result = "(" & $col.colType & ","

    # Do vertex ID and address/hash
    if col.colType == CtStorage:
      result &= col.stoRoot.toStr
      if col.stoAddr != EthAddress.default:
        result &= ",%" & $col.stoAddr.toHex
    else:
      result &= VertexID(col.colType).toStr

    # Do the Merkle hash key
    if not root.isValid:
      result &= ",£ø"
    else:
      let rc = base.api.getKeyRc(col.base.ctx.mpt, root)
      if rc.isErr:
        result &= "," & $rc.error
      elif rc.value.isValid:
        result &= ",£" & rc.value.to(Hash256).data.toHex
      else:
        result &= ",£ø"

    result &= ")"
  elif not col.isNil:
    result &= "$?"


proc rootHashEmpty*(
    base: AristoBaseRef;
    col: CoreDbColRef;
    info: static[string];
      ): CoreDbRc[bool] =
  let col = AristoColRef(col)
  if not col.isValid:
    return err(TrieInvalid.toError(base, info, HashNotAvailable))

  let root = col.to(VertexID)
  if not root.isValid:
    return ok(true)
  return ok(false)

proc rootHash*(
    base: AristoBaseRef;
    col: CoreDbColRef;
    info: static[string];
      ): CoreDbRc[Hash256] =
  let col = AristoColRef(col)
  if not col.isValid:
    return err(TrieInvalid.toError(base, info, HashNotAvailable))

  let root = col.to(VertexID)
  if not root.isValid:
    return ok(EMPTY_ROOT_HASH)

  let
    api = base.api
    mpt = base.ctx.mpt
  ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

  let key = block:
    let rc = api.getKeyRc(mpt, root)
    if rc.isErr:
      doAssert rc.error in {GetKeyNotFound, GetKeyUpdateNeeded}
      return err(rc.error.toError(base, info, HashNotAvailable))
    rc.value
  ok key.to(Hash256)


proc swapCtx*(base: AristoBaseRef; ctx: CoreDbCtxRef): CoreDbCtxRef =
  doAssert not ctx.isNil
  result = base.ctx

  # Set read-write access and install
  base.ctx = AristoCoreDbCtxRef(ctx)
  base.api.reCentre(base.ctx.mpt).isOkOr:
    raiseAssert "swapCtx() failed: " & $error


proc persistent*(
    base: AristoBaseRef;
    fid: uint64;
    info: static[string];
      ): CoreDbRc[void] =
  let
    api = base.api
    mpt = base.ctx.mpt
    rc = api.persist(mpt, fid)
  if rc.isOk:
    ok()
  elif api.level(mpt) == 0:
    err(rc.error.toError(base, info))
  else:
    err(rc.error.toError(base, info, TxPending))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc destroy*(base: AristoBaseRef; eradicate: bool) =
  base.api.finish(base.ctx.mpt, eradicate)


func init*(T: type AristoBaseRef; db: CoreDbRef; adb: AristoDbRef): T =
  result = T(
    parent: db,
    api:    AristoApiRef.init())

  # Create initial context
  let ctx = AristoCoreDbCtxRef(
    base: result,
    mpt:  adb)
  ctx.methods = ctx.ctxMethods
  result.ctx = db.bless ctx

  when CoreDbEnableApiProfiling:
    let profApi = AristoApiProfRef.init(result.api, adb.backend)
    result.api = profApi
    result.ctx.mpt.backend = profApi.be


proc init*(
    T: type CoreDbCtxRef;
    base: AristoBaseRef;
    colState: Hash256;
    colType: CoreDbColType;
      ): CoreDbRc[CoreDbCtxRef] =
  const info = "fromTxFn()"

  if colType.ord == 0:
    return err(aristo.GenericError.toError(base, info, ColUnacceptable))
  let
    api = base.api
    vid = VertexID(colType)
    key = colState.to(HashKey)

    # Find `(vid,key)` on transaction stack
    inx = block:
      let rc = api.findTx(base.ctx.mpt, vid, key)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

    # Fork MPT descriptor that provides `(vid,key)`
    newMpt = block:
      let rc = api.forkTx(base.ctx.mpt, inx)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

  # Create new context
  let ctx = AristoCoreDbCtxRef(
    base: base,
    mpt:  newMpt)
  ctx.methods = ctx.ctxMethods
  ok(base.parent.bless ctx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
