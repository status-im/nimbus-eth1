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
    gq: seq[AristoChildDbRef]    ## Garbage queue, deferred disposal
    accCache: CoreDxAccRef       ## Pre-configured accounts descriptor to share
    mptCache: MptCacheArray      ## Pre-configured accounts descriptor to share

  MptCacheArray =
    array[AccountsTrie .. high(CoreDbSubTrie), AristoCoreDxMptRef]

  AristoChildDbRef = ref AristoChildDbObj
  AristoChildDbObj = object
    ## Sub-handle for triggering destructor when it goes out of scope.
    base: AristoBaseRef          ## Local base descriptor
    root: VertexID               ## State root, may be zero unless account
    when CoreDbEnableApiTracking:
      address: EthAddress        ## For storage tree debugging
    accPath: PathID              ## Needed for storage tries
    mpt: AristoDbRef             ## Descriptor, may be copy of `base.adb`
    saveMode: CoreDbSaveFlags    ## When to store/discard
    txError: CoreDbErrorCode     ## Transaction error code: account or MPT

  AristoCoreDxMptRef = ref object of CoreDxMptRef
    ## Some extension to recover embedded state
    ctx: AristoChildDbRef        ## Embedded state, typical var name: `cMpt`

  AristoCoreDxAccRef = ref object of CoreDxAccRef
    ## Some extension to recover embedded account. Note that the `cached`
    ## version shares the `ctx` entry referred to entry with
    ## `mptCache[AccountsTrie].ctx` from the cache array.
    ctx: AristoChildDbRef        ## Embedded state, typical var name: `cAcc`

  AristoCoreDbTrie* = ref object of CoreDbTrieRef
    ## Vertex ID wrapper, optinally with *MPT* context
    kind: CoreDbSubTrie          ## Current sub-trie
    root: VertexID               ## State root, (may differ from `kind.ord`)
    when CoreDbEnableApiTracking:
      address: EthAddress        ## For storage tree debugging
    accPath: PathID              ## Needed for storage tries
    ctx: AristoChildDbRef        ## *MPT* context, may be `nil`
    reset: bool                  ## Delete request

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

proc gc*(base: AristoBaseRef) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb/adb " & info

# -------------------------------

func isValid(ctx: AristoChildDbRef): bool =
  not ctx.isNil

func isValid(trie: CoreDbTrieRef): bool =
  not trie.isNil and trie.ready

func to(vid: CoreDbTrieRef; T: type VertexID): T =
  if vid.isValid:
    return vid.AristoCoreDbTrie.root

func to(address: EthAddress; T: type PathID): T =
  HashKey.fromBytes(address.keccakHash.data).value.to(T)

# ------------------------------------------------------------------------------
# Auto destructor should appear before constructor
# to prevent **cannot bind another `=destroy` error**
# ------------------------------------------------------------------------------

proc `=destroy`(cMpt: var AristoChildDbObj) =
  ## Auto destructor
  let mpt = cMpt.mpt
  if not mpt.isNil:
    let base = cMpt.base
    if mpt != base.adb:                 # Not the shared descriptor?
      #
      # The argument `cMpt` will be deleted, so provide another one. The
      # `mpt` descriptor must be added to the GC queue which will be
      # destructed later on a clean environment.
      #
      base.gq.add AristoChildDbRef(
        base:     base,
        mpt:      mpt,
        saveMode: cMpt.saveMode)
    elif cMpt.saveMode == AutoSave:     # Otherwise there is nothing to do
      #
      # Prepend cached entry. There is only one needed as it refers to
      # the same shared `mpt` descriptor.
      #
      if base.gq.len == 0 or
         base.gq[0].saveMode != AutoSave:
        base.gq = AristoChildDbRef(
          base:     base,
          mpt:      mpt,
          saveMode: cMpt.saveMode) & base.gq

# -------------------------------

func toCoreDbAccount(
    cMpt: AristoChildDbRef;
    acc: AristoAccount;
    address: EthAddress;
      ): CoreDbAccount =
  let db = cMpt.base.parent
  result = CoreDbAccount(
    address:  address,
    nonce:    acc.nonce,
    balance:  acc.balance,
    codeHash: acc.codeHash)
  if acc.storageID.isValid:
    result.stoTrie = db.bless AristoCoreDbTrie(
      kind:    StorageTrie,
      root:    acc.storageID,
      accPath: address.to(PathID),
      ctx:     cMpt)
    when CoreDbEnableApiTracking:
      result.stoTrie.AristoCoreDbTrie.address = address


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
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  db.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    aErr:     e))

# Forward declaration, see below in public section
func toError*(
    e: (VertexID,AristoError);
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef


func toRc[T](
    rc: Result[T,(VertexID,AristoError)];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err rc.error.toError(db, info, error)

func toRc[T](
    rc: Result[T,AristoError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err((VoidTrieID,rc.error).toError(db, info, error))


func toVoidRc[T](
    rc: Result[T,(VertexID,AristoError)];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err rc.error.toError(db, info, error)

# ------------------------------------------------------------------------------
# Private constructor
# ------------------------------------------------------------------------------

proc newTrieCtx(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[AristoCoreDbTrie] =
  base.gc()
  var
    trie = AristoCoreDbTrie(trie)
  let
    db = base.parent
    api = base.api

  # Update `trie` argument, handle default settings
  block validateRoot:
    if not trie.isValid:
      trie = AristoCoreDbTrie(kind: GenericTrie, root: GenericTrieID)
      break validateRoot
    elif trie.root.isValid:
      if trie.kind != StorageTrie or LEAST_FREE_VID <= trie.root.distinctBase:
        break validateRoot
    elif trie.kind == StorageTrie: # note: StorageTrie.ord == 0
      break validateRoot
    elif trie.root == VertexID(trie.kind):
      break validateRoot

    # Handle error condition
    var vid = trie.root
    if not vid.isValid:
      vid = VertexID(trie.kind)
    let error = (vid,MptRootUnacceptable)
    return err(error.toError(base.parent, info, RootUnacceptable))
    # End: block validateRoot

  # Get normalised `svaeMode` and `MPT`
  let (mode, mpt) = case saveMode:
    of TopShot:
      (saveMode, ? api.forkTop(base.adb).toRc(db, info))
    of Companion:
      (saveMode, ? api.fork(base.adb).toRc(db, info))
    of Shared, AutoSave:
      if base.adb.backend.isNil:
        (Shared, base.adb)
      else:
        (saveMode, base.adb)

  block body:
    if mode == Shared:
      if trie.kind == StorageTrie:
        # Create new storage trie descriptor
        break body

      # Use cached descriptor
      let ctx = base.mptCache[trie.kind].ctx
      if not trie.ctx.isValid:
        trie.ctx = ctx
        return ok(trie)
      if trie.ctx == ctx:
        return ok(trie)
      # Oops, error

    # Make sure that the root object is usable on this MPT descriptor
    if trie.ctx.isValid:
      return err(VidContextLocked.toError(db, info, TrieLocked))
    # End: block sharedBody

  trie.ctx = AristoChildDbRef(
    base:     base,
    root:     trie.root,
    accPath:  trie.accPath,
    mpt:      mpt,
    saveMode: mode,
    txError:  MptTxPending)
  when CoreDbEnableApiTracking:
    trie.AristoCoreDbTrie.ctx.address = trie.address

  ok((db.bless trie).AristoCoreDbTrie)

# ------------------------------------------------------------------------------
# Private `MPT` or account call back functions
# ------------------------------------------------------------------------------

proc getTrieFn(
    cMpt: AristoChildDbRef;
      ): CoreDbTrieRef =
  let
    root = cMpt.root
    kind = if LEAST_FREE_VID <= root.distinctBase: StorageTrie
           else: CoreDbSubTrie(root)

  doAssert kind != StorageTrie or cMpt.accPath.isValid
  result = cMpt.base.parent.bless AristoCoreDbTrie(
    kind:      kind,
    root:      root,
    accPath:   cMpt.accPath,
    ctx:       cMpt)
  when CoreDbEnableApiTracking:
    result.AristoCoreDbTrie.address = cMpt.address


proc persistent(
    cMpt: AristoChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    base = cMpt.base
    mpt = cMpt.mpt
    api = base.api
    db = base.parent
    rc = api.stow(mpt, persistent = true)

  # note that `gc()` may call `persistent()` so there is no `base.gc()` here
  if rc.isOk:
    ok()
  elif api.level(mpt) == 0:
    err(rc.error.toError(db, info))
  else:
    err(rc.error.toError(db, info, cMpt.txError))


proc forget(
    cMpt: AristoChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    base = cMpt.base
    mpt = cMpt.mpt
  cMpt.mpt = AristoDbRef(nil) # disables `=destroy`
  base.gc()
  result = ok()

  if mpt != base.adb:
    let
      api = base.api
      rc = api.forget(cMpt.mpt)
    if rc.isErr:
      let db = base.parent
      result = err(rc.error.toError(db, info))

# ------------------------------------------------------------------------------
# Private `MPT` call back functions
# ------------------------------------------------------------------------------

proc mptMethods(cMpt: AristoChildDbRef): CoreDbMptFns =
  ## Hexary trie database handlers

  proc mptBackend(
      cMpt: AristoChildDbRef;
        ): CoreDbMptBackendRef =
    let
      db = cMpt.base.parent
      mpt = cMpt.mpt
    db.bless AristoCoreDbMptBE(adb: mpt)

  proc mptPersistent(
    cMpt: AristoChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
    cMpt.base.gc() # note that `gc()` also may call `persistent()`
    cMpt.persistent info

  proc mptFetch(
      cMpt: AristoChildDbRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[Blob] =
    let db = cMpt.base.parent

    # Some pathological behaviour observed with storage tries due to lazy
    # update. The `fetchPayload()` does not now about this and would complain
    # an error different from `FetchPathNotFound`.
    if not cMpt.root.isValid:
      return err((VoidTrieID,MptRootMissing).toError(db, info, MptNotFound))

    let
      mpt = cMpt.mpt
      api = cMpt.base.api
      rc = api.fetchPayload(mpt, cMpt.root, k)
    if rc.isOk:
      api.serialise(mpt, rc.value).toRc(db, info)
    elif rc.error[1] != FetchPathNotFound:
      err(rc.error.toError(db, info))
    else:
      err rc.error.toError(db, info, MptNotFound)

  proc mptMerge(
      cMpt: AristoChildDbRef;
      k: openArray[byte];
      v: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let
      db = cMpt.base.parent
      api = cMpt.base.api
      mpt = cMpt.mpt
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
      return err(rc.error.toError(db, info))
    ok()

  proc mptDelete(
      cMpt: AristoChildDbRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let
      db = cMpt.base.parent
      api = cMpt.base.api
      mpt = cMpt.mpt

    if not cMpt.root.isValid and cMpt.accPath.isValid:
      # This is insane but legit. A storage trie was announced for an account
      # but no data have been added, yet.
      return ok()

    let rc = api.delete(mpt, cMpt.root, k, cMpt.accPath)
    if rc.isErr:
      if rc.error[1] == DelPathNotFound:
        return err(rc.error.toError(db, info, MptNotFound))
      return err(rc.error.toError(db, info))

    if rc.value:
      # Trie has become empty
      cMpt.root = VoidTrieID

    ok()

  proc mptHasPath(
      cMpt: AristoChildDbRef;
      key: openArray[byte];
      info: static[string];
        ): CoreDbRc[bool] =
    let
      mpt = cMpt.mpt
      api = cMpt.base.api
      rc = api.hasPath(mpt, cMpt.root, key)
    if rc.isErr:
      let db = cMpt.base.parent
      return err(rc.error.toError(db, info))
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
      cMpt.getTrieFn(),

    isPruningFn: proc(): bool =
      true,

    persistentFn: proc(): CoreDbRc[void] =
      cMpt.mptPersistent("persistentFn()"),

    forgetFn: proc(): CoreDbRc[void] =
      cMpt.forget("forgetFn()"))

# ------------------------------------------------------------------------------
# Private account call back functions
# ------------------------------------------------------------------------------

proc accMethods(cAcc: AristoChildDbRef): CoreDbAccFns =
  ## Hexary trie database handlers

  proc accBackend(
      cAcc: AristoChildDbRef;
        ): CoreDbAccBackendRef =
    let
      db = cAcc.base.parent
      mpt = cAcc.mpt
    db.bless AristoCoreDbAccBE(adb: mpt)

  proc accPersistent(
    cAcc: AristoChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
    cAcc.base.gc() # note that `gc()` also may call `persistent()`
    cAcc.persistent info

  proc accCloneMpt(
      cAcc: AristoChildDbRef;
      info: static[string];
        ): CoreDbRc[CoreDxMptRef] =
    let base = cAcc.base
    base.gc()
    ok(base.mptCache[AccountsTrie])

  proc accFetch(
      cAcc: AristoChildDbRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[CoreDbAccount] =
    let
      db = cAcc.base.parent
      api = cAcc.base.api
      mpt = cAcc.mpt
      pyl = block:
        let
          key = address.keccakHash.data
          rc = api.fetchPayload(mpt, cAcc.root, key)
        if rc.isOk:
          rc.value
        elif rc.error[1] != FetchPathNotFound:
          return err(rc.error.toError(db, info))
        else:
          return err(rc.error.toError(db, info, AccNotFound))

    if pyl.pType != AccountData:
      let vePair = (pyl.account.storageID, PayloadTypeUnsupported)
      return err(vePair.toError(db, info & "/" & $pyl.pType))
    ok cAcc.toCoreDbAccount(pyl.account, address)

  proc accMerge(
      cAcc: AristoChildDbRef;
      acc: CoreDbAccount;
      info: static[string];
        ): CoreDbRc[void] =
    let
      db = cAcc.base.parent
      api = cAcc.base.api
      mpt = cAcc.mpt
      key = acc.address.keccakHash.data
      val = acc.toPayloadRef()
      rc = api.mergePayload(mpt, cAcc.root, key, val)
    if rc.isErr:
      return err(rc.error.toError(db, info))
    ok()

  proc accDelete(
      cAcc: AristoChildDbRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[void] =
    let
      db = cAcc.base.parent
      api = cAcc.base.api
      mpt = cAcc.mpt
      key = address.keccakHash.data
      rc = api.delete(mpt, cAcc.root, key, VOID_PATH_ID)
    if rc.isErr:
      if rc.error[1] ==  DelPathNotFound:
        return err(rc.error.toError(db, info, AccNotFound))
      return err(rc.error.toError(db, info))
    ok()

  proc accStoFlush(
      cAcc: AristoChildDbRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[void] =
    let
      db = cAcc.base.parent
      api = cAcc.base.api
      mpt = cAcc.mpt
      key = address.keccakHash.data
      pyl = api.fetchPayload(mpt, cAcc.root, key).valueOr:
        return ok()

    # Use storage ID from account and delete that sub-trie
    if pyl.pType == AccountData:
      let stoID = pyl.account.storageID
      if stoID.isValid:
        let rc = api.delTree(mpt, stoID, address.to(PathID))
        if rc.isErr:
          return err(rc.error.toError(db, info))
    ok()

  proc accHasPath(
      cAcc: AristoChildDbRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[bool] =
    let
      db = cAcc.base.parent
      api = cAcc.base.api
      mpt = cAcc.mpt
      key = address.keccakHash.data
      rc = api.hasPath(mpt, cAcc.root, key)
    if rc.isErr:
      return err(rc.error.toError(db, info))
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
      cAcc.forget("forgetFn()"))

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

func toError*(
    e: (VertexID,AristoError);
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  db.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    vid:      e[0],
    aErr:     e[1]))

func toVoidRc*[T](
    rc: Result[T,AristoError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err((VoidTrieID,rc.error).toError(db, info, error))


proc gc*(base: AristoBaseRef) =
  ## Run deferred destructors when it is safe. It is needed to run the
  ## destructors at the same scheduler level as the API call back functions.
  ## Any of the API functions can be intercepted by the `=destroy()` hook at
  ## inconvenient times so that atomicity would be violated if the actual
  ## destruction took place in `=destroy()`.
  ##
  ## Note: In practice the `db.gq` queue should not have much more than one
  ##       entry and mostly be empty.
  const
    info = "gc()"
  let
    api = base.api
  var
    resetQ = 0
    first = 0

  if 0 < base.gq.len:
    # Check for a shared entry
    if base.gq[0].mpt == base.adb:
      first = 1
      let cMpt = base.gq[0]
      if 0 < api.level(cMpt.mpt):
        resetQ = 1
      else:
        let rc = cMpt.persistent info
        if rc.isErr:
          let error = rc.error.errorPrint
          debug logTxt info, saveMode=cMpt.saveMode, error

    # Do other entries
    for n in first ..< base.gq.len:
      let cMpt = base.gq[n]
      # FIXME: Currently no strategy for `Companion` and `TopShot`
      let rc = base.api.forget(cMpt.mpt)
      if rc.isErr:
        let error = rc.error.toError(base.parent, info).errorPrint
        debug logTxt info, saveMode=cMpt.saveMode, error

    base.gq.setLen(resetQ)

# ---------------------

func to*(dsc: CoreDxMptRef, T: type AristoDbRef): T =
  AristoCoreDxMptRef(dsc).ctx.mpt

func rootID*(dsc: CoreDxMptRef): VertexID  =
  dsc.AristoCoreDxMptRef.ctx.root

func txTop*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.api.txTop(base.adb).toRc(base.parent, info)

proc txBegin*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.api.txBegin(base.adb).toRc(base.parent, info)

# ---------------------

proc getLevel*(base: AristoBaseRef): int =
  base.api.level(base.adb)

proc tryHash*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    info: static[string];
      ): CoreDbRc[Hash256] =
  let trie = trie.AristoCoreDbTrie
  if not trie.ctx.isValid:
    return err(MptContextMissing.toError(base.parent, info, HashNotAvailable))

  let root = trie.to(VertexID)
  if not root.isValid:
    return ok(EMPTY_ROOT_HASH)

  let rc = base.api.getKeyRc(trie.ctx.mpt, root)
  if rc.isErr:
    return err(rc.error.toError(base.parent, info, HashNotAvailable))

  ok rc.value.to(Hash256)


proc triePrint*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
      ): string =
  if not trie.isNil:
    if not trie.isValid:
      result &= "$?"
    else:
      let
        trie = trie.AristoCoreDbTrie
        rc = base.tryHash(trie, "triePrint()")
      result = "(" & $trie.kind & "," & trie.root.toStr
      if trie.accPath.isValid:
        result &= ",@" & $trie.accPath
      elif trie.kind == StorageTrie:
        result &= ",@ø"
      when CoreDbEnableApiTracking:
        if trie.address != EthAddress.default:
          result &= ",%" & $trie.address.toHex
      if rc.isErr:
        result &= "," & $rc.error.AristoCoreDbError.aErr
      else:
        result &= ",£" & (if rc.value.isValid: rc.value.data.toHex else: "ø")
      result &= ")"


proc rootHash*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    info: static[string];
      ): CoreDbRc[Hash256] =
  let
    db = base.parent
    api = base.api
    trie = trie.AristoCoreDbTrie
  if not trie.ctx.isValid:
    return err(MptContextMissing.toError(db, info, HashNotAvailable))
  let
    mpt = trie.ctx.mpt
    root = trie.to(VertexID)

  if not root.isValid:
    return ok(EMPTY_ROOT_HASH)

  ? api.hashify(mpt).toVoidRc(db, info, HashNotAvailable)

  let key = block:
    let rc = api.getKeyRc(mpt, root)
    if rc.isErr:
      doAssert rc.error in {GetKeyNotFound,GetKeyUpdateNeeded}
      return err(rc.error.toError(base.parent, info, HashNotAvailable))
    rc.value

  ok key.to(Hash256)

proc rootHash*(mpt: CoreDxMptRef): VertexID =
  AristoCoreDxMptRef(mpt).ctx.root


proc getTrie*(
    base: AristoBaseRef;
    kind: CoreDbSubTrie;
    root: Hash256;
    address: Option[EthAddress];
    info: static[string];
      ): CoreDbRc[CoreDbTrieRef] =
  let
    db = base.parent
    adb = base.adb
    api = base.api
    ethAddr = (if address.isNone: EthAddress.default else: address.unsafeGet)
    path = (if address.isNone: VOID_PATH_ID else: ethAddr.to(PathID))
  base.gc() # update pending changes

  if kind == StorageTrie and not path.isValid:
    return err(aristo.UtilsAccPathMissing.toError(db, info, AccAddrMissing))

  if not root.isValid:
    var trie = AristoCoreDbTrie(
      kind:    kind,
      root:    VertexID(kind),
      accPath: path,
      reset:   AccountsTrie < kind)
    when CoreDbEnableApiTracking:
      trie.address = ethAddr
    return ok(db.bless trie)

  ? api.hashify(adb).toVoidRc(db, info, HashNotAvailable)

  # Check whether hash is available as state root on main trie
  block:
    let rc = api.getKeyRc(adb, VertexID kind)
    if rc.isErr:
      doAssert rc.error == GetKeyNotFound
    elif rc.value == root.to(HashKey):
      doAssert kind != StorageTrie or path.isValid
      var trie = AristoCoreDbTrie(
        kind:    kind,
        root:    VertexID(kind),
        accPath: path)
      when CoreDbEnableApiTracking:
        trie.address = ethAddr
      return ok(db.bless trie)
    else:
      discard

  err(aristo.GenericError.toError(db, info, RootNotFound))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc verify*(base: AristoBaseRef; trie: CoreDbTrieRef): bool =
  let trie = trie.AristoCoreDbTrie
  if trie.kind != StorageTrie:
    return true
  if not trie.accPath.isValid:
    return false
  if not trie.root.isValid:
    return true
  let path = trie.accPath.to(NibblesSeq)
  if base.api.hikeUp(path, AccountsTrieID, base.adb).isOk:
    return true
  false

proc newMptHandler*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[CoreDxMptRef] =
  let
    trie = ? base.newTrieCtx(trie, saveMode, info)
    db = base.parent
    api = base.api
  if trie.kind == StorageTrie and trie.root.isValid:
    let
      adb = base.adb
      path = trie.accPath.to(NibblesSeq)
      rc =  api.hikeUp(path, AccountsTrieID, adb)
    if rc.isErr:
      return err(rc.error[1].toError(db, info, AccNotFound))
  if trie.reset:
    # Note that `reset` only applies to non-dynamic trie roots with vertex ID
    # beween `VertexID(2) ..< LEAST_FREE_VID`. At the moment, this applies to
    # `GenericTrie` type sub-tries somehow emulating the behaviour of a new
    # empty MPT on the legacy database (handle with care, though.)
    let
      rc = api.delTree(trie.ctx.mpt, trie.root, VOID_PATH_ID)
    if rc.isErr:
      return err(rc.error.toError(db, info, AutoFlushFailed))
    trie.reset = false

  ok(base.parent.bless AristoCoreDxMptRef(
    ctx:     trie.ctx,
    methods: trie.ctx.mptMethods()))


proc newAccHandler*(
    base: AristoBaseRef;
    trie: CoreDbTrieRef;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[CoreDxAccRef] =
  let trie = ? base.newTrieCtx(trie, saveMode, info)
  if trie.kind != AccountsTrie:
    let error = (trie.root,AccRootUnacceptable)
    return err(error.toError(base.parent, info, RootUnacceptable))

  # For error handling (default is `MptTxPending`)
  trie.ctx.txError = AccTxPending

  ok(base.parent.bless AristoCoreDxAccRef(
    ctx:     trie.ctx,
    methods: trie.ctx.accMethods()))


proc destroy*(base: AristoBaseRef; flush: bool) =
  # Don't recycle pre-configured shared handler
  base.accCache.AristoCoreDxAccRef.ctx.mpt = AristoDbRef(nil)
  for w in base.mptCache:
    # w is a AristoCoreDxMptRef
    w.ctx.mpt = AristoDbRef(nil)

  # Clean up desctructor queue
  base.gc()

  # Close descriptor
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

  # Provide pre-configured handlers to share
  for trie in AccountsTrie .. high(CoreDbSubTrie):
    let cMpt = AristoChildDbRef(
      base:     result,
      root:     VertexID(trie),
      mpt:      adb,
      saveMode: Shared,
      txError:  MptTxPending)
    result.mptCache[trie] = db.bless AristoCoreDxMptRef(
      ctx:     cMpt,
      methods: cMpt.mptMethods())

  # Cached trie with different methods
  let cAcc = result.mptCache[AccountsTrie].ctx
  result.accCache = db.bless AristoCoreDxAccRef(
    ctx:     cAcc,
    methods: cAcc.accMethods())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
