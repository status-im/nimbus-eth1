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
  eth/[common, trie/nibbles],
  stew/byteutils,
  results,
  ../../../aristo,
  ../../../aristo/aristo_filter/filter_scheduler,
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

  AristoCoreDxAccRef = ref object of CoreDxAccRef
    base: AristoBaseRef          ## Local base descriptor

  AristoCoreDxMptRef = ref object of CoreDxMptRef
    base: AristoBaseRef          ## Local base descriptor
    mptRoot: VertexID            ## State root, may be zero unless account
    accPath: PathID              ## Needed for storage columns
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

func to(address: EthAddress; T: type PathID): T =
  HashKey.fromBytes(address.keccakHash.data).value.to(T)

func resetCol(colType: CoreDbColType): bool =
  ## Check whether to reset some non-dynamic column when instantiating. It
  ## emulates the behaviour of a new empty MPT on the legacy database.
  colType == CtGeneric or
    (high(CoreDbColType) < colType and colType.ord < LEAST_FREE_VID)

# -------------------------------

func toCoreDbAccount(
    cAcc: AristoCoreDxAccRef;
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

proc mptMethods(cMpt: AristoCoreDxMptRef): CoreDbMptFns =
  ## Generic columns database handlers
  let
    cMpt = cMpt        # So it can savely be captured
    base = cMpt.base   # Will not change and can be captured
    db = base.parent   # Ditto
    api = base.api     # Ditto
    mpt = base.ctx.mpt # Ditto

  proc mptBackend(): CoreDbMptBackendRef =
    db.bless AristoCoreDbMptBE(adb: mpt)

  proc mptColFn(): CoreDbColRef =
    let col =
      if LEAST_FREE_VID <= cMpt.mptRoot.distinctBase:
        assert cMpt.accPath.isValid # debug mode only
        AristoColRef(
          base:    base,
          colType: CtStorage,
          stoRoot: cMpt.mptRoot,
          stoAddr: cMpt.address)
      else:
        AristoColRef(
          base:    base,
          colType: CoreDbColType(cMpt.mptRoot))
    db.bless col

  proc mptFetch(key: openArray[byte]): CoreDbRc[Blob] =
    const info = "fetchFn()"

    # Some pathological behaviour observed with storage column due to lazy
    # update. The `fetchPayload()` does not now about this and would complain
    # an error different from `FetchPathNotFound`.
    let rootVID = cMpt.mptRoot
    if not rootVID.isValid:
      return err((VoidVID,MptRootMissing).toError(base, info, MptNotFound))

    let rc = api.fetchPayload(mpt, rootVID, key)
    if rc.isOk:
      api.serialise(mpt, rc.value).toRc(base, info)
    elif rc.error[1] != FetchPathNotFound:
      err(rc.error.toError(base, info))
    else:
      err rc.error.toError(base, info, MptNotFound)

  proc mptMerge(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
    const info = "mergeFn()"

    # Provide root ID on-the-fly
    let rootOk = cMpt.mptRoot.isValid
    if not rootOk:
      cMpt.mptRoot = api.vidFetch(mpt, pristine=true)

    let rc = api.merge(mpt, cMpt.mptRoot, k, v, cMpt.accPath)
    if rc.isErr:
      # Re-cycle unused ID (prevents from leaking IDs)
      if not rootOk:
        api.vidDispose(mpt, cMpt.mptRoot)
        cMpt.mptRoot = VoidVID
      return err(rc.error.toError(base, info))
    ok()

  proc mptDelete(key: openArray[byte]): CoreDbRc[void] =
    const info = "deleteFn()"

    if not cMpt.mptRoot.isValid and cMpt.accPath.isValid:
      # This is insane but legit. A storage column was announced for an account
      # but no data have been added, yet.
      return ok()
    let rc = api.delete(mpt, cMpt.mptRoot, key, cMpt.accPath)
    if rc.isErr:
      if rc.error[1] == DelPathNotFound:
        return err(rc.error.toError(base, info, MptNotFound))
      return err(rc.error.toError(base, info))

    if rc.value:
      # Column has become empty
      cMpt.mptRoot = VoidVID
    ok()

  proc mptHasPath(key: openArray[byte]): CoreDbRc[bool] =
    const info = "hasPathFn()"

    let rc = api.hasPath(mpt, cMpt.mptRoot, key)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok(rc.value)


  CoreDbMptFns(
    backendFn: proc(): CoreDbMptBackendRef =
      mptBackend(),

    fetchFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      mptFetch(k),

    deleteFn: proc(k: openArray[byte]): CoreDbRc[void] =
      mptDelete(k),

    mergeFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      mptMerge(k, v),

    hasPathFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      mptHasPath(k),

    getColFn: proc(): CoreDbColRef =
      mptColFn(),

    isPruningFn: proc(): bool =
      true)

# ------------------------------------------------------------------------------
# Private account call back functions
# ------------------------------------------------------------------------------

proc accMethods(cAcc: AristoCoreDxAccRef): CoreDbAccFns =
  ## Account columns database handlers
  let
    cAcc = cAcc        # So it can savely be captured
    base = cAcc.base   # Will not change and can be captured
    db = base.parent   # Ditto
    api = base.api     # Ditto
    mpt = base.ctx.mpt # Ditto

  proc getColFn(): CoreDbColRef =
    db.bless AristoColRef(
      base: base,
      colType: CtAccounts)

  proc accCloneMpt(): CoreDbRc[CoreDxMptRef] =
    ok(AristoCoreDxMptRef(
      base:    base,
      mptRoot: AccountsVID))

  proc accFetch(address: EthAddress): CoreDbRc[CoreDbAccount] =
    const info = "acc/fetchFn()"

    let pyl = block:
      let
        key = address.keccakHash.data
        rc = api.fetchPayload(mpt, AccountsVID, key)
      if rc.isOk:
        rc.value
      elif rc.error[1] != FetchPathNotFound:
        return err(rc.error.toError(base, info))
      else:
        return err(rc.error.toError(base, info, AccNotFound))

    if pyl.pType != AccountData:
      let vidErrPair = (pyl.account.storageID, PayloadTypeUnsupported)
      return err(vidErrPair.toError(base, info & "/" & $pyl.pType))
    ok cAcc.toCoreDbAccount(pyl.account, address)

  proc accMerge(account: CoreDbAccount): CoreDbRc[void] =
    const info = "acc/mergeFn()"

    let
      key = account.address.keccakHash.data
      val = account.toPayloadRef()
      rc = api.mergePayload(mpt, AccountsVID, key, val)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok()

  proc accDelete(address: EthAddress): CoreDbRc[void] =
    const info = "acc/deleteFn()"

    let
      key = address.keccakHash.data
      rc = api.delete(mpt, AccountsVID, key, VOID_PATH_ID)
    if rc.isErr:
      if rc.error[1] == DelPathNotFound:
        return err(rc.error.toError(base, info, AccNotFound))
      return err(rc.error.toError(base, info))
    ok()

  proc accStoFlush(address: EthAddress): CoreDbRc[void] =
    const info = "stoFlushFn()"

    let
      key = address.keccakHash.data
      pyl = api.fetchPayload(mpt, AccountsVID, key).valueOr:
        return ok()

    # Use storage ID from account and delete that column
    if pyl.pType == AccountData:
      let stoID = pyl.account.storageID
      if stoID.isValid:
        let rc = api.delTree(mpt, stoID, address.to(PathID))
        if rc.isErr:
          return err(rc.error.toError(base, info))
    ok()

  proc accHasPath(address: EthAddress): CoreDbRc[bool] =
    const info = "hasPathFn()"

    let
      key = address.keccakHash.data
      rc = api.hasPath(mpt, AccountsVID, key)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok(rc.value)


  CoreDbAccFns(
    getMptFn: proc(): CoreDbRc[CoreDxMptRef] =
      accCloneMpt(),

    fetchFn: proc(address: EthAddress): CoreDbRc[CoreDbAccount] =
      accFetch(address),

    deleteFn: proc(address: EthAddress): CoreDbRc[void] =
      accDelete(address),

    stoFlushFn: proc(address: EthAddress): CoreDbRc[void] =
      accStoFlush(address),

    mergeFn: proc(acc: CoreDbAccount): CoreDbRc[void] =
      accMerge(acc),

    hasPathFn: proc(address: EthAddress): CoreDbRc[bool] =
      accHasPath(address),

    getColFn: proc(): CoreDbColRef =
      getColFn(),

    isPruningFn: proc(): bool =
      true)

# ------------------------------------------------------------------------------
# Private context call back functions
# ------------------------------------------------------------------------------

proc ctxMethods(cCtx: AristoCoreDbCtxRef): CoreDbCtxFns =
  let
    cCtx = cCtx      # So it can savely be captured
    base = cCtx.base # Will not change and can be captured
    db = base.parent # Ditto
    api = base.api   # Ditto
    mpt = cCtx.mpt   # Ditto

  proc ctxNewCol(
      colType: CoreDbColType;
      colState: Hash256;
      address: Option[EthAddress];
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


  proc ctxGetMpt(col: CoreDbColRef): CoreDbRc[CoreDxMptRef] =
    const
      info = "ctx/getMptFn()"
    let
      col = AristoColRef(col)
    var
      reset = false
      newMpt: AristoCoreDxMptRef
    if not col.isValid:
      reset = true
      newMpt = AristoCoreDxMptRef(
        mptRoot: GenericVID,
        accPath: VOID_PATH_ID)

    elif col.colType == CtStorage:
      newMpt = AristoCoreDxMptRef(
        mptRoot: col.stoRoot,
        accPath: col.stoAddr.to(PathID),
        address: col.stoAddr)
      if col.stoRoot.isValid:
        if col.stoRoot.distinctBase < LEAST_FREE_VID:
          let error = (col.stoRoot,MptRootUnacceptable)
          return err(error.toError(base, info, RootUnacceptable))
        # Verify path if there is a particular storge root VID
        let rc = api.hikeUp(newMpt.accPath.to(NibblesSeq), AccountsVID, mpt)
        if rc.isErr:
          return err(rc.error[1].toError(base, info, AccNotFound))
    else:
      reset = col.colType.resetCol()
      newMpt = AristoCoreDxMptRef(
        mptRoot: VertexID(col.colType),
        accPath: VOID_PATH_ID)

    # Reset column. This a emulates the behaviour of a new empty MPT on the
    # legacy database.
    if reset:
      let rc = api.delTree(mpt, newMpt.mptRoot, VOID_PATH_ID)
      if rc.isErr:
        return err(rc.error.toError(base, info, AutoFlushFailed))
      col.reset = false

    newMpt.base = base
    newMpt.methods = newMpt.mptMethods()
    ok(db.bless newMpt)

  proc ctxGetAcc(col: CoreDbColRef): CoreDbRc[CoreDxAccRef] =
    const info = "getAccFn()"

    let col = AristoColRef(col)
    if col.colType != CtAccounts:
      let error = (AccountsVID, AccRootUnacceptable)
      return err(error.toError(base, info, RootUnacceptable))

    let acc = AristoCoreDxAccRef(base: base)
    acc.methods = acc.accMethods()

    ok(db.bless acc)

  proc ctxForget() =
    api.forget(mpt).isOkOr:
      raiseAssert "forgetFn(): " & $error


  CoreDbCtxFns(
    newColFn: proc(
        col: CoreDbColType;
        colState: Hash256;
        address: Option[EthAddress];
          ): CoreDbRc[CoreDbColRef] =
      ctxNewCol(col, colState, address),

    getMptFn: proc(col: CoreDbColRef; prune: bool): CoreDbRc[CoreDxMptRef] =
      ctxGetMpt(col),

    getAccFn: proc(col: CoreDbColRef; prune: bool): CoreDbRc[CoreDxAccRef] =
      ctxGetAcc(col),

    forgetFn: proc() =
      ctxForget())

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

proc toJournalOldestStateRoot*(base: AristoBaseRef): Hash256 =
  let
    adb = base.ctx.mpt
    be = adb.backend
  if not be.isNil:
    let jrn = be.journal
    if not jrn.isNil:
      let qid = jrn[^1]
      if qid.isValid:
        let rc = base.api.getFilUbe(adb, qid)
        if rc.isOk:
          return rc.value.trg
  EMPTY_ROOT_HASH

# ---------------------

func to*(dsc: CoreDxMptRef, T: type AristoDbRef): T =
  AristoCoreDxMptRef(dsc).base.ctx.mpt

func to*(dsc: CoreDxMptRef, T: type AristoApiRef): T =
  AristoCoreDxMptRef(dsc).base.api

func rootID*(dsc: CoreDxMptRef): VertexID  =
  AristoCoreDxMptRef(dsc).mptRoot

func txTop*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.api.txTop(base.adb).toRc(base, info)

proc txBegin*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.api.txBegin(base.ctx.mpt).toRc(base, info)

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
  base.api.reCentre(base.ctx.mpt)


proc persistent*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    api = base.api
    mpt = base.ctx.mpt
    rc = api.stow(mpt, persistent = true)
  if rc.isOk:
    ok()
  elif api.level(mpt) == 0:
    err(rc.error.toError(base, info))
  else:
    err(rc.error.toError(base, info, TxPending))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc destroy*(base: AristoBaseRef; flush: bool) =
  base.api.finish(base.ctx.mpt, flush)


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

    # Fork MPT descriptor that provides `(vid,key)`
    newMpt = block:
      let rc = api.forkWith(base.ctx.mpt, vid, key)
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
