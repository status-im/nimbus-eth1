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
    adb: AristoDbRef             ## Aristo MPT database
    api*: AristoApiRef           ## Api functions can be re-directed

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
  StorageTrieID = VertexID(StorageTrie)
  GenericTrieID = VertexID(GenericTrie)

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

template logTxt(info: static[string]): static[string] =
  "CoreDb/adb " & info

# -------------------------------

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

# ------------------------------------------------------------------------------
# Private `MPT` call back functions
# ------------------------------------------------------------------------------

proc mptMethods(cMpt: AristoCoreDxMptRef): CoreDbMptFns =
  ## Hexary trie database handlers

  proc mptBackend(
      cMpt: AristoCoreDxMptRef;
        ): CoreDbMptBackendRef =
    let base = cMpt.base
    base.parent.bless AristoCoreDbMptBE(adb: base.adb)

  proc mptTrieFn(
      cMpt: AristoCoreDxMptRef;
        ): CoreDbTrieRef =
    let trie =
      if LEAST_FREE_VID <= cMpt.root.distinctBase:
        assert cMpt.accPath.isValid # debug mode only
        AristoCoreDbTrie(
          base:    cMpt.base,
          kind:    StorageTrie,
          stoRoot: cMpt.root,
          stoAddr: cMpt.address)
      else:
        AristoCoreDbTrie(
          base: cMpt.base,
          kind: CoreDbSubTrie(cMpt.root))

    cMpt.base.parent.bless trie

  proc mptPersistent(
    cMpt: AristoCoreDxMptRef;
    info: static[string];
      ): CoreDbRc[void] =
    let
      base = cMpt.base
      mpt = base.adb
      api = base.api
      rc = api.stow(mpt, persistent = true)
    if rc.isOk:
      ok()
    elif api.level(mpt) == 0:
      err(rc.error.toError(base, info))
    else:
      err(rc.error.toError(base, info, MptTxPending))

  proc mptFetch(
      cMpt: AristoCoreDxMptRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[Blob] =
    let
      base = cMpt.base
      root = cMpt.root

    # Some pathological behaviour observed with storage tries due to lazy
    # update. The `fetchPayload()` does not now about this and would complain
    # an error different from `FetchPathNotFound`.
    if not root.isValid:
      return err((VoidTrieID,MptRootMissing).toError(base, info, MptNotFound))

    let
      mpt = base.adb
      api = base.api
      rc = api.fetchPayload(mpt, root, k)
    if rc.isOk:
      api.serialise(mpt, rc.value).toRc(base, info)
    elif rc.error[1] != FetchPathNotFound:
      err(rc.error.toError(base, info))
    else:
      err rc.error.toError(base, info, MptNotFound)

  proc mptMerge(
      cMpt: AristoCoreDxMptRef;
      k: openArray[byte];
      v: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cMpt.base
      api = base.api
      mpt = base.adb
      rootOk = cMpt.root.isValid

    # Provide root ID on-the-fly
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

  proc mptDelete(
      cMpt: AristoCoreDxMptRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cMpt.base
      api = base.api
      mpt = base.adb

    if not cMpt.root.isValid and cMpt.accPath.isValid:
      # This is insane but legit. A storage trie was announced for an account
      # but no data have been added, yet.
      return ok()

    let rc = api.delete(mpt, cMpt.root, k, cMpt.accPath)
    if rc.isErr:
      if rc.error[1] == DelPathNotFound:
        return err(rc.error.toError(base, info, MptNotFound))
      return err(rc.error.toError(base, info))

    if rc.value:
      # Trie has become empty
      cMpt.root = VoidTrieID
    ok()

  proc mptHasPath(
      cMpt: AristoCoreDxMptRef;
      key: openArray[byte];
      info: static[string];
        ): CoreDbRc[bool] =
    let
      base = cMpt.base
      mpt = base.adb
      api = base.api
      rc = api.hasPath(mpt, cMpt.root, key)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok(rc.value)

  CoreDbMptFns(
    backendFn: proc(): CoreDbMptBackendRef =
      cMpt.mptBackend(),

    fetchFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      cMpt.mptFetch(k, "fetchFn()"),

    deleteFn: proc(k: openArray[byte]): CoreDbRc[void] =
      cMpt.mptDelete(k, "deleteFn()"),

    mergeFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      cMpt.mptMerge(k, v, "mergeFn()"),

    hasPathFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      cMpt.mptHasPath(k, "hasPathFn()"),

    getTrieFn: proc(): CoreDbTrieRef =
      cMpt.mptTrieFn(),

    isPruningFn: proc(): bool =
      true,

    persistentFn: proc(): CoreDbRc[void] =
      cMpt.mptPersistent("persistentFn()"),

    forgetFn: proc(): CoreDbRc[void] =
      discard)

# ------------------------------------------------------------------------------
# Private account call back functions
# ------------------------------------------------------------------------------

proc accMethods(cAcc: AristoCoreDxAccRef): CoreDbAccFns =
  ## Hexary trie database handlers

  proc accBackend(
      cAcc: AristoCoreDxAccRef;
        ): CoreDbAccBackendRef =
    let base = cAcc.base
    base.parent.bless AristoCoreDbAccBE(adb: base.adb)

  proc getTrieFn(
      cMpt: AristoCoreDxAccRef;
        ): CoreDbTrieRef =
    let base = cAcc.base
    base.parent.bless AristoCoreDbTrie(
      base: base,
      kind: AccountsTrie)

  proc accPersistent(
    cAcc: AristoCoreDxAccRef;
    info: static[string];
      ): CoreDbRc[void] =
    let
      base = cAcc.base
      mpt = base.adb
      api = base.api
      rc = api.stow(mpt, persistent = true)
    if rc.isOk:
      ok()
    elif api.level(mpt) == 0:
      err(rc.error.toError(base, info))
    else:
      err(rc.error.toError(base, info, AccTxPending))

  proc accCloneMpt(
      cAcc: AristoCoreDxAccRef;
      info: static[string];
        ): CoreDbRc[CoreDxMptRef] =
    ok(AristoCoreDxMptRef(
      base: cAcc.base,
      root: AccountsTrieID))

  proc accFetch(
      cAcc: AristoCoreDxAccRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[CoreDbAccount] =
    let
      base = cAcc.base
      api = base.api
      mpt = base.adb
      pyl = block:
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
      let vePair = (pyl.account.storageID, PayloadTypeUnsupported)
      return err(vePair.toError(base, info & "/" & $pyl.pType))
    ok cAcc.toCoreDbAccount(pyl.account, address)

  proc accMerge(
      cAcc: AristoCoreDxAccRef;
      acc: CoreDbAccount;
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cAcc.base
      api = base.api
      mpt = base.adb
      key = acc.address.keccakHash.data
      val = acc.toPayloadRef()
      rc = api.mergePayload(mpt, AccountsTrieID, key, val)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok()

  proc accDelete(
      cAcc: AristoCoreDxAccRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cAcc.base
      api = base.api
      mpt = base.adb
      key = address.keccakHash.data
      rc = api.delete(mpt, AccountsTrieID, key, VOID_PATH_ID)
    if rc.isErr:
      if rc.error[1] == DelPathNotFound:
        return err(rc.error.toError(base, info, AccNotFound))
      return err(rc.error.toError(base, info))
    ok()

  proc accStoFlush(
      cAcc: AristoCoreDxAccRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cAcc.base
      api = base.api
      mpt = base.adb
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

  proc accHasPath(
      cAcc: AristoCoreDxAccRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[bool] =
    let
      base = cAcc.base
      api = cAcc.base.api
      mpt = cAcc.base.adb
      key = address.keccakHash.data
      rc = api.hasPath(mpt, AccountsTrieID, key)
    if rc.isErr:
      return err(rc.error.toError(base, info))
    ok(rc.value)

  CoreDbAccFns(
    backendFn: proc(): CoreDbAccBackendRef =
      cAcc.accBackend(),

    newMptFn: proc(): CoreDbRc[CoreDxMptRef] =
      cAcc.accCloneMpt("newMptFn()"),

    fetchFn: proc(address: EthAddress): CoreDbRc[CoreDbAccount] =
      cAcc.accFetch(address, "fetchFn()"),

    deleteFn: proc(address: EthAddress): CoreDbRc[void] =
      cAcc.accDelete(address, "deleteFn()"),

    stoFlushFn: proc(address: EthAddress): CoreDbRc[void] =
      cAcc.accStoFlush(address, "stoFlushFn()"),

    mergeFn: proc(acc: CoreDbAccount): CoreDbRc[void] =
      cAcc.accMerge(acc, "mergeFn()"),

    hasPathFn: proc(address: EthAddress): CoreDbRc[bool] =
      cAcc.accHasPath(address, "hasPathFn()"),

    getTrieFn: proc(): CoreDbTrieRef =
      cAcc.getTrieFn(),

    isPruningFn: proc(): bool =
      true,

    persistentFn: proc(): CoreDbRc[void] =
      cAcc.accPersistent("persistentFn()"),

    forgetFn: proc(): CoreDbRc[void] =
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
  AristoCoreDxMptRef(dsc).base.adb

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
  base.api.txBegin(base.adb).toRc(base, info)

# ---------------------

proc getLevel*(base: AristoBaseRef): int =
  base.api.level(base.adb)

proc tryHash*(
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

  let rc = base.api.getKeyRc(trie.base.adb, root)
  if rc.isErr:
    return err(rc.error.toError(base, info, HashNotAvailable))

  ok rc.value.to(Hash256)

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
    mpt = base.adb
  ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

  let key = block:
    let rc = api.getKeyRc(mpt, root)
    if rc.isErr:
      doAssert rc.error in {GetKeyNotFound,GetKeyUpdateNeeded}
      return err(rc.error.toError(base, info, HashNotAvailable))
    rc.value

  ok key.to(Hash256)


proc newTrie*(
    base: AristoBaseRef;
    kind: CoreDbSubTrie;
    root: Hash256;
    address: Option[EthAddress];
    info: static[string];
      ): CoreDbRc[CoreDbTrieRef] =
  let
    adb = base.adb
    api = base.api
    trie = AristoCoreDbTrie(
      base: base,
      kind: kind)

  if kind == StorageTrie:
    if address.isNone:
      let error = aristo.UtilsAccPathMissing
      return err(error.toError(base, info, AccAddrMissing))
    trie.stoAddr = address.unsafeGet

  if not root.isValid:
    return ok(base.parent.bless trie)

  # Reset non-dynamic trie when instantiating. This applies to root IDs beween
  # `VertexID(2) .. LEAST_FREE_VID`. It emulates the behaviour of a new empty
  # MPT on the legacy database.
  if AccountsTrie < kind and kind.ord < LEAST_FREE_VID:
    trie.reset = true

  # Update hashes in order to verify the trie state root.
  ? api.hashify(adb).toVoidRc(base, info, HashNotAvailable)

  # Make sure that the hash is available as state root on the main trie
  let rc = api.getKeyRc(adb, VertexID kind)
  if rc.isErr:
    doAssert rc.error == GetKeyNotFound
  elif rc.value == root.to(HashKey):
    return ok(base.parent.bless trie)

  err(aristo.GenericError.toError(base, info, RootNotFound))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc verify*(base: AristoBaseRef; trie: CoreDbTrieRef): bool =
  let trie = trie.AristoCoreDbTrie
  if not trie.base.isNil:
    if trie.kind != StorageTrie:
      return true
    if LEAST_FREE_VID < trie.stoRoot.distinctBase:
      let path = trie.stoAddr.to(PathID).to(NibblesSeq)
      if base.api.hikeUp(path, AccountsTrieID, base.adb).isOk:
        return true
  false

proc newMptHandler*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    info: static[string];
      ): CoreDbRc[CoreDxMptRef] =
  let
    trie = AristoCoreDbTrie(trie)
    api = base.api

  var
    reset = false
    mpt: AristoCoreDxMptRef
  if not trie.isValid:
    reset = true
    mpt = AristoCoreDxMptRef(
      root:    GenericTrieID,
      accPath: VOID_PATH_ID)

  elif trie.kind == StorageTrie:
    mpt = AristoCoreDxMptRef(
      root:    trie.stoRoot,
      accPath: trie.stoAddr.to(PathID),
      address: trie.stoAddr)

    if trie.stoRoot.isValid:
      if trie.stoRoot.distinctBase < LEAST_FREE_VID:
        let error = (trie.stoRoot,MptRootUnacceptable)
        return err(error.toError(base, info, RootUnacceptable))
      # Verify path if there is a particular storge root VID
      let rc = api.hikeUp(mpt.accPath.to(NibblesSeq), AccountsTrieID, base.adb)
      if rc.isErr:
        return err(rc.error[1].toError(base, info, AccNotFound))
  else:
    reset = AccountsTrie < trie.kind
    mpt = AristoCoreDxMptRef(
      root:    VertexID(trie.kind),
      accPath: VOID_PATH_ID)

  # Reset trie. This a emulates the behaviour of a new empty MPT on the
  # legacy database.
  if reset:
    let rc = base.api.delTree(base.adb, mpt.root, VOID_PATH_ID)
    if rc.isErr:
      return err(rc.error.toError(base, info, AutoFlushFailed))
    trie.reset = false

  mpt.base = base
  mpt.methods = mpt.mptMethods()

  ok(base.parent.bless mpt)


proc newAccHandler*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    info: static[string];
      ): CoreDbRc[CoreDxAccRef] =
  let trie = AristoCoreDbTrie(trie)
  if trie.kind != AccountsTrie:
    let error = (AccountsTrieID, AccRootUnacceptable)
    return err(error.toError(base, info, RootUnacceptable))

  let acc = AristoCoreDxAccRef(base: base)
  acc.methods = acc.accMethods()

  ok(base.parent.bless acc)


proc destroy*(base: AristoBaseRef; flush: bool) =
  base.api.finish(base.adb, flush)


func init*(T: type AristoBaseRef; db: CoreDbRef; adb: AristoDbRef): T =
  result = T(
    parent: db,
    api:    AristoApiRef.init(),
    adb:    adb)

  when CoreDbEnableApiProfiling:
    let profApi = AristoApiProfRef.init(result.api, adb.backend)
    result.api = profApi
    result.adb.backend = profApi.be

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
