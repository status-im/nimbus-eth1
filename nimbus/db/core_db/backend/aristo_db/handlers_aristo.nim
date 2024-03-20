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
  ../../base,
  ../../base/base_desc,
  ./common_desc

type
  AristoBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    api*: AristoApiRef           ## Api functions can be re-directed
    ctx*: AristoCoreDbCtxRef     ## Currently active context

  AristoCoreDbCtxRef = ref object of CoreDbCtxRef
    base: AristoBaseRef          ## Local base descriptor
    mpt: AristoDbRef             ## Aristo MPT database

  AristoCoreDxAccRef = ref object of CoreDxAccRef
    base: AristoBaseRef          ## Local base descriptor

  AristoCoreDxMptRef = ref object of CoreDxMptRef
    base: AristoBaseRef          ## Local base descriptor
    root: VertexID               ## State root, may be zero unless account
    accPath: PathID              ## Needed for storage tries
    address: EthAddress          ## For storage tree debugging

  AristoCoreDbTrie* = ref object of CoreDbTrieRef
    ## Vertex ID wrapper, optionally with *MPT* context
    base: AristoBaseRef
    case kind: CoreDbSubTrie     ## Current sub-trie
    of StorageTrie:
      stoRoot: VertexID          ## State root, may be zero if unknown
      stoAddr: EthAddress        ## Account where the storage trie belongs to
    else:
      reset: bool                ## Internal delete request

  AristoCoreDbMptBE* = ref object of CoreDbMptBackendRef
    adb*: AristoDbRef

  AristoCoreDbAccBE* = ref object of CoreDbAccBackendRef
    adb*: AristoDbRef

const
  VoidTrieID = VertexID(0)
  AccountsTrieID = VertexID(AccountsTrie)
  GenericTrieID = VertexID(GenericTrie)

when false:
  const
    StorageTrieID = VertexID(StorageTrie)

logScope:
  topics = "aristo-hdl"

static:
  doAssert StorageTrie.ord == 0
  doAssert AccountsTrie.ord == 1
  doAssert low(CoreDbSubTrie).ord == 0
  doAssert high(CoreDbSubTrie).ord < LEAST_FREE_VID

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func isValid(trie: CoreDbTrieRef): bool =
  not trie.isNil and trie.ready

func to(trie: CoreDbTrieRef; T: type VertexID): T =
  if trie.isValid:
    let trie = AristoCoreDbTrie(trie)
    if trie.kind == StorageTrie:
      return trie.stoRoot
    return VertexID(trie.kind)

func to(address: EthAddress; T: type PathID): T =
  HashKey.fromBytes(address.keccakHash.data).value.to(T)

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
    result.stoTrie = db.bless AristoCoreDbTrie(
      base:    cAcc.base,
      kind:    StorageTrie,
      stoRoot: acc.storageID,
      stoAddr: address)

func toPayloadRef(acc: CoreDbAccount): PayloadRef =
  PayloadRef(
    pType:       AccountData,
    account: AristoAccount(
      nonce:     acc.nonce,
      balance:   acc.balance,
      storageID: acc.stoTrie.to(VertexID),
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
  err((VoidTrieID,rc.error).toError(base, info, error))


func toVoidRc[T](
    rc: Result[T,(VertexID,AristoError)];
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err rc.error.toError(base, info, error)

# -------------------------------

proc tryHash(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    info: static[string];
      ): CoreDbRc[Hash256] =
  let trie = trie.AristoCoreDbTrie
  if not trie.isValid:
    return err(TrieInvalid.toError(base, info, HashNotAvailable))

  let root = trie.to(VertexID)
  if not root.isValid:
    return ok(EMPTY_ROOT_HASH)

  let rc = base.api.getKeyRc(trie.base.ctx.mpt, root)
  if rc.isErr:
    return err(rc.error.toError(base, info, HashNotAvailable))

  ok rc.value.to(Hash256)

# ------------------------------------------------------------------------------
# Private `MPT` call back functions
# ------------------------------------------------------------------------------

proc mptMethods(cMpt: AristoCoreDxMptRef): CoreDbMptFns =
  ## Hexary trie database handlers
  let
    cMpt = cMpt        # So it can savely be captured
    base = cMpt.base   # Will not change and can be captured
    db = base.parent   # Ditto
    api = base.api     # Ditto
    mpt = base.ctx.mpt # Ditto

  proc mptBackend(): CoreDbMptBackendRef =
    db.bless AristoCoreDbMptBE(adb: mpt)

  proc mptTrieFn(): CoreDbTrieRef =
    let trie =
      if LEAST_FREE_VID <= cMpt.root.distinctBase:
        assert cMpt.accPath.isValid # debug mode only
        AristoCoreDbTrie(
          base:    base,
          kind:    StorageTrie,
          stoRoot: cMpt.root,
          stoAddr: cMpt.address)
      else:
        AristoCoreDbTrie(
          base: base,
          kind: CoreDbSubTrie(cMpt.root))

    db.bless trie

  proc mptPersistent(): CoreDbRc[void] =
    const info = "persistentFn()"

    let rc = api.stow(mpt, persistent = true)
    if rc.isOk:
      ok()
    elif api.level(mpt) == 0:
      err(rc.error.toError(base, info))
    else:
      err(rc.error.toError(base, info, MptTxPending))

  proc mptFetch(key: openArray[byte]): CoreDbRc[Blob] =
    const info = "fetchFn()"

    # Some pathological behaviour observed with storage tries due to lazy
    # update. The `fetchPayload()` does not now about this and would complain
    # an error different from `FetchPathNotFound`.
    let root = cMpt.root
    if not root.isValid:
      return err((VoidTrieID,MptRootMissing).toError(base, info, MptNotFound))

    let rc = api.fetchPayload(mpt, root, key)
    if rc.isOk:
      api.serialise(mpt, rc.value).toRc(base, info)
    elif rc.error[1] != FetchPathNotFound:
      err(rc.error.toError(base, info))
    else:
      err rc.error.toError(base, info, MptNotFound)

  proc mptMerge(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
    const info = "mergeFn()"

    # Provide root ID on-the-fly
    let rootOk = cMpt.root.isValid
    if not rootOk:
      cMpt.root = api.vidFetch(mpt, pristine=true)

    let rc = api.merge(mpt, cMpt.root, k, v, cMpt.accPath)
    if rc.isErr:
      # Re-cycle unused ID (prevents from leaking IDs)
      if not rootOk:
        api.vidDispose(mpt, cMpt.root)
        cMpt.root = VoidTrieID
      return err(rc.error.toError(base, info))
    ok()

  proc mptDelete(key: openArray[byte]): CoreDbRc[void] =
    const info = "deleteFn()"

    if not cMpt.root.isValid and cMpt.accPath.isValid:
      # This is insane but legit. A storage trie was announced for an account
      # but no data have been added, yet.
      return ok()

    let rc = api.delete(mpt, cMpt.root, key, cMpt.accPath)
    if rc.isErr:
      if rc.error[1] == DelPathNotFound:
        return err(rc.error.toError(base, info, MptNotFound))
      return err(rc.error.toError(base, info))

    if rc.value:
      # Trie has become empty
      cMpt.root = VoidTrieID
    ok()

  proc mptHasPath(key: openArray[byte]): CoreDbRc[bool] =
    const info = "hasPathFn()"

    let rc = api.hasPath(mpt, cMpt.root, key)
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

    getTrieFn: proc(): CoreDbTrieRef =
      mptTrieFn(),

    isPruningFn: proc(): bool =
      true,

    persistentFn: proc(): CoreDbRc[void] =
      mptPersistent())

# ------------------------------------------------------------------------------
# Private account call back functions
# ------------------------------------------------------------------------------

proc accMethods(cAcc: AristoCoreDxAccRef): CoreDbAccFns =
  ## Hexary trie database handlers
  let
    cAcc = cAcc        # So it can savely be captured
    base = cAcc.base   # Will not change and can be captured
    db = base.parent   # Ditto
    api = base.api     # Ditto
    mpt = base.ctx.mpt # Ditto

  proc accBackend(): CoreDbAccBackendRef =
    db.bless AristoCoreDbAccBE(adb: mpt)

  proc getTrieFn(): CoreDbTrieRef =
    db.bless AristoCoreDbTrie(
      base: base,
      kind: AccountsTrie)

  proc accPersistent(): CoreDbRc[void] =
    const info = "persistentFn()"

    let rc = api.stow(mpt, persistent = true)
    if rc.isOk:
      ok()
    elif api.level(mpt) == 0:
      err(rc.error.toError(base, info))
    else:
      err(rc.error.toError(base, info, AccTxPending))

  proc accCloneMpt(): CoreDbRc[CoreDxMptRef] =
    ok(AristoCoreDxMptRef(
      base: base,
      root: AccountsTrieID))

  proc accFetch(address: EthAddress): CoreDbRc[CoreDbAccount] =
    const info = "fetchFn()"

    let pyl = block:
      let
        key = address.keccakHash.data
        rc = api.fetchPayload(mpt, AccountsTrieID, key)
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
    const info = "mergeFn()"

    let
      key = account.address.keccakHash.data
      val = account.toPayloadRef()
      rc = api.mergePayload(mpt, AccountsTrieID, key, val)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok()

  proc accDelete(address: EthAddress): CoreDbRc[void] =
    const info = "deleteFn()"

    let
      key = address.keccakHash.data
      rc = api.delete(mpt, AccountsTrieID, key, VOID_PATH_ID)
    if rc.isErr:
      if rc.error[1] == DelPathNotFound:
        return err(rc.error.toError(base, info, AccNotFound))
      return err(rc.error.toError(base, info))
    ok()

  proc accStoFlush(address: EthAddress): CoreDbRc[void] =
    const info = "stoFlushFn()"

    let
      key = address.keccakHash.data
      pyl = api.fetchPayload(mpt, AccountsTrieID, key).valueOr:
        return ok()

    # Use storage ID from account and delete that sub-trie
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
      rc = api.hasPath(mpt, AccountsTrieID, key)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok(rc.value)


  CoreDbAccFns(
    backendFn: proc(): CoreDbAccBackendRef =
      accBackend(),

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

    getTrieFn: proc(): CoreDbTrieRef =
      getTrieFn(),

    isPruningFn: proc(): bool =
      true,

    persistentFn: proc(): CoreDbRc[void] =
      accPersistent())

# ------------------------------------------------------------------------------
# Private context call back functions
# ------------------------------------------------------------------------------

proc ctxMethods(cCtx: AristoCoreDbCtxRef): CoreDbCtxFns =
  let
    cCtx = cCtx        # So it can savely be captured
    base = cCtx.base   # Will not change and can be captured
    db = base.parent   # Ditto
    api = base.api     # Ditto
    mpt = cCtx.mpt     # Ditto

  proc ctxNewTrie(
      kind: CoreDbSubTrie;
      root: Hash256;
      address: Option[EthAddress];
      info: static[string];
        ): CoreDbRc[CoreDbTrieRef] =
    let trie = AristoCoreDbTrie(
      base: base,
      kind: kind)

    if kind == StorageTrie:
      if address.isNone:
        let error = aristo.UtilsAccPathMissing
        return err(error.toError(base, info, AccAddrMissing))
      trie.stoAddr = address.unsafeGet

    if not root.isValid:
      return ok(db.bless trie)

    # Reset non-dynamic trie when instantiating. This applies to root IDs beween
    # `VertexID(2) .. LEAST_FREE_VID`. It emulates the behaviour of a new empty
    # MPT on the legacy database.
    if AccountsTrie < kind and kind.ord < LEAST_FREE_VID:
      trie.reset = true

    # Update hashes in order to verify the trie state root.
    ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

    # Make sure that the hash is available as state root on the main trie
    let rc = api.getKeyRc(mpt, VertexID kind)
    if rc.isErr:
      doAssert rc.error == GetKeyNotFound
    elif rc.value == root.to(HashKey):
      return ok(db.bless trie)

    err(aristo.GenericError.toError(base, info, RootNotFound))


  proc ctxGetMpt(
      trie: CoreDbTrieRef;
      info: static[string];
        ): CoreDbRc[CoreDxMptRef] =
    let
      trie = AristoCoreDbTrie(trie)
    var
      reset = false
      newMpt: AristoCoreDxMptRef
    if not trie.isValid:
      reset = true
      newMpt = AristoCoreDxMptRef(
        root:    GenericTrieID,
        accPath: VOID_PATH_ID)

    elif trie.kind == StorageTrie:
      newMpt = AristoCoreDxMptRef(
        root:    trie.stoRoot,
        accPath: trie.stoAddr.to(PathID),
        address: trie.stoAddr)
      if trie.stoRoot.isValid:
        if trie.stoRoot.distinctBase < LEAST_FREE_VID:
          let error = (trie.stoRoot,MptRootUnacceptable)
          return err(error.toError(base, info, RootUnacceptable))
        # Verify path if there is a particular storge root VID
        let rc = api.hikeUp(newMpt.accPath.to(NibblesSeq), AccountsTrieID, mpt)
        if rc.isErr:
          return err(rc.error[1].toError(base, info, AccNotFound))
    else:
      reset = AccountsTrie < trie.kind
      newMpt = AristoCoreDxMptRef(
        root:    VertexID(trie.kind),
        accPath: VOID_PATH_ID)

    # Reset trie. This a emulates the behaviour of a new empty MPT on the
    # legacy database.
    if reset:
      let rc = api.delTree(mpt, newMpt.root, VOID_PATH_ID)
      if rc.isErr:
        return err(rc.error.toError(base, info, AutoFlushFailed))
      trie.reset = false

    newMpt.base = base
    newMpt.methods = newMpt.mptMethods()

    ok(db.bless newMpt)


  proc ctxGetAcc(
      trie: CoreDbTrieRef;
      info: static[string];
        ): CoreDbRc[CoreDxAccRef] =
    let trie = AristoCoreDbTrie(trie)
    if trie.kind != AccountsTrie:
      let error = (AccountsTrieID, AccRootUnacceptable)
      return err(error.toError(base, info, RootUnacceptable))

    let acc = AristoCoreDxAccRef(base: base)
    acc.methods = acc.accMethods()

    ok(db.bless acc)

  CoreDbCtxFns(
    fromTxFn: proc(root: Hash256; kind: CoreDbSubTrie): CoreDbRc[CoreDbCtxRef] =
      const info = "fromTxFn()"
      err(aristo.NotImplemented.toError(base, info, base_desc.NotImplemented)),

    swapFn: proc(cty: CoreDbCtxRef): CoreDbCtxRef =
      doAssert not cty.isNil
      base.ctx.swap(AristoCoreDbCtxRef(cty)),

    newTrieFn: proc(
        trie: CoreDbSubTrie;
        root: Hash256;
        address: Option[EthAddress];
          ): CoreDbRc[CoreDbTrieRef] =
      ctxNewTrie(trie, root, address, "newTrieFn()"),

    getMptFn: proc(trie: CoreDbTrieRef; prune: bool): CoreDbRc[CoreDxMptRef] =
      ctxGetMpt(trie, "newMptFn()"),

    getAccFn: proc(trie: CoreDbTrieRef; prune: bool): CoreDbRc[CoreDxAccRef] =
      ctxGetAcc(trie, "newAccFn()"),

    forgetFn: proc() =
      api.forget(mpt).isOkOr:
        raiseAssert "forgetFn(): " & $error
      discard)

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
  err((VoidTrieID,rc.error).toError(base, info, error))

# ---------------------

func to*(dsc: CoreDxMptRef, T: type AristoDbRef): T =
  AristoCoreDxMptRef(dsc).base.ctx.mpt

func rootID*(dsc: CoreDxMptRef): VertexID  =
  dsc.AristoCoreDxMptRef.root

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

# ---------------------

proc getLevel*(base: AristoBaseRef): int =
  base.api.level(base.ctx.mpt)

proc triePrint*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
      ): string =
  if trie.isValid:
    let
      trie = trie.AristoCoreDbTrie
      rc = base.tryHash(trie, "triePrint()")
    result = "(" & $trie.kind
    if trie.kind == StorageTrie:
      result &= trie.stoRoot.toStr
      if trie.stoAddr != EthAddress.default:
        result &= ",%" & $trie.stoAddr.toHex
    else:
      result &= VertexID(trie.kind).toStr
    if rc.isErr:
      result &= "," & $rc.error.AristoCoreDbError.aErr
    else:
      result &= ",£" & (if rc.value.isValid: rc.value.data.toHex else: "ø")
    result &= ")"
  elif not trie.isNil:
    result &= "$?"


proc rootHash*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    info: static[string];
      ): CoreDbRc[Hash256] =
  let trie = trie.AristoCoreDbTrie
  if not trie.isValid:
    return err(TrieInvalid.toError(base, info, HashNotAvailable))

  let root = trie.to(VertexID)
  if not root.isValid:
    return ok(EMPTY_ROOT_HASH)

  let
    api = base.api
    mpt = base.ctx.mpt
  ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

  let key = block:
    let rc = api.getKeyRc(mpt, root)
    if rc.isErr:
      doAssert rc.error in {GetKeyNotFound,GetKeyUpdateNeeded}
      return err(rc.error.toError(base, info, HashNotAvailable))
    rc.value

  ok key.to(Hash256)

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
