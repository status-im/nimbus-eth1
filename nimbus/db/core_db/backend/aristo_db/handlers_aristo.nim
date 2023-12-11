# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  chronicles,
  eth/common,
  results,
  ../../../aristo,
  ../../../aristo/aristo_desc,
  ../../base,
  ../../base/base_desc,
  ./common_desc

import
  ../../../aristo/[aristo_check, aristo_debug, aristo_hashify]

var
  noisy* = false

type
  AristoBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    adb: AristoDbRef             ## Aristo MPT database
    gq: seq[AristoChildDbRef]    ## Garbage queue, deferred disposal
    accCache: CoreDxAccRef       ## Pre-configured accounts descriptor to share
    mptCache: CoreDxMptRef       ## Pre-configured accounts descriptor to share

  AristoChildDbRef = ref AristoChildDbObj
  AristoChildDbObj = object
    ## Sub-handle for triggering destructor when it goes out of scope
    base: AristoBaseRef          ## Local base descriptor
    root: VertexID               ## State root
    mpt: AristoDbRef             ## Descriptor, may be copy of `base.adb`
    saveMode: CoreDbSaveFlags    ## When to store/discard
    txError: CoreDbErrorCode     ## Transaction error code: account or MPT

  AristoCoreDxMptRef = ref object of CoreDxMptRef
    ## Some extendion to recover embedded state
    ctx: AristoChildDbRef        ## Embedded state, typical var name: `cMpt`

  AristoCoreDxAccRef = ref object of CoreDxAccRef
    ## Some extendion to recover embedded state
    ctx: AristoChildDbRef        ## Embedded state, typical var name: `cAcc`

  AristoCoreDbVid* = ref object of CoreDbVidRef
    ## Vertex ID wrapper, optinally with *MPT* context
    ctx: AristoDbRef             ## Optional *MPT* context, might be `nil`
    aVid: VertexID               ## Refers to root vertex
    createOk: bool               ## Create new root vertex when appropriate
    expHash: Hash256             ## Deferred validation

  AristoCoreDbMptBE* = ref object of CoreDbMptBackendRef
    adb*: AristoDbRef

  AristoCoreDbAccBE* = ref object of CoreDbAccBackendRef
    adb*: AristoDbRef

logScope:
  topics = "aristo-hdl"

proc gc*(base: AristoBaseRef) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb/adb " & info

# -------------------------------

func isValid(vid: CoreDbVidRef): bool =
  not vid.isNil and vid.ready

func to*(vid: CoreDbVidRef; T: type VertexID): T =
  if vid.isValid:
    return vid.AristoCoreDbVid.aVid

func createOk(vid: CoreDbVidRef): bool =
  if vid.isValid:
    return vid.AristoCoreDbVid.createOk

# -------------------------------

func toCoreDbAccount(
    cMpt: AristoChildDbRef;
    acc: AristoAccount;
      ): CoreDbAccount =
  let db = cMpt.base.parent
  CoreDbAccount(
    nonce:      acc.nonce,
    balance:    acc.balance,
    codeHash:   acc.codeHash,
    storageVid: db.bless AristoCoreDbVid(ctx: cMpt.mpt, aVid: acc.storageID))

func toPayloadRef(acc: CoreDbAccount): PayloadRef =
  PayloadRef(
    pType:       AccountData,
    account: AristoAccount(
      nonce:     acc.nonce,
      balance:   acc.balance,
      storageID: acc.storageVid.to(VertexID),
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
  err((VertexID(0),rc.error).toError(db, info, error))


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
# Private auto destructor
# ------------------------------------------------------------------------------

proc `=destroy`(cMpt: var AristoChildDbObj) =
  ## Auto destructor
  let
    base = cMpt.base
    mpt = cMpt.mpt
  if not mpt.isNil:
    block body:
      # Do some heuristics to avoid duplicates:
      block addToBatchQueue:
        if mpt != base.adb:              # not base descriptor?
          if mpt.level == 0:             # no transaction pending?
            break addToBatchQueue        # add to destructor queue
          else:
            break body                   # ignore `mpt`

        if cMpt.saveMode != AutoSave:    # is base descriptor and no auto-save?
          break body                     # ignore `mpt`

        if base.gq.len == 0:             # empty batch queue?
          break addToBatchQueue          # add to destructor queue

        if base.gq[0].mpt == mpt or      # not the same as first entry?
           base.gq[^1].mpt == mpt:       # not the same as last entry?
          break body                     # ignore `mpt`

      # Add to destructor batch queue. Note that the `adb` destructor might
      # have a pending transaction which might be resolved while queued for
      # persistent saving.
      base.gq.add AristoChildDbRef(
        base:     base,
        mpt:      mpt,
        saveMode: cMpt.saveMode)

      # End body

    const noisy = false
    if noisy: echo "*** adb/=destroy",
      " isAdb=", (mpt == base.adb),
      " saveMode=", cMpt.saveMode,
      " nForked=", mpt.nForked,
      " level=", mpt.level,
      " #gq=", base.gq.len,
      "" # , "\n    db\n    ", mdb.pp(backendOk=true)

# ------------------------------------------------------------------------------
# Private `MPT` or account call back functions
# ------------------------------------------------------------------------------

proc rootVidFn(
    cMpt: AristoChildDbRef;
      ): CoreDbVidRef =
  let
    db = cMpt.base.parent
    mpt = cMpt.mpt
  db.bless AristoCoreDbVid(ctx: mpt, aVid: cMpt.root)

proc persistent(
    cMpt: AristoChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    base = cMpt.base
    mpt = cMpt.mpt
    db = base.parent
    rc = mpt.stow(persistent = true)

  let noisy = false # cMpt.saveMode notin {AutoSave,Shared}
  if noisy:
    let dmp {.used.} = (if 0 < mpt.nForked or 0 < mpt.level: ""
                        else: "\n    db\n    " & mpt.pp(backendOk=true))
    echo "*** adb/persistent",
      " saveMode=", cMpt.saveMode,
      " txError=", cMpt.txError,
      " #gq=", base.gq.len,
      " nForked=", mpt.nForked,
      " level=", mpt.level,
      " rc=", (if rc.isOk: "ok" else: $rc.error),
      "" # , dmp

  # note that `gc()` may call `persistent()` so there is no `base.gc()` here
  if rc.isOk:
    ok()
  elif mpt.level == 0:
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
      db = base.parent
      rc = cMpt.mpt.forget()
    if rc.isErr:
      result = err(rc.error.toError(db, info))

    if noisy:
      let dmp {.used.} = (if 0 < mpt.nForked or 0 < mpt.level: ""
                          else: "\n    db\n    " & mpt.pp(backendOk=true))
      echo "*** adb/forget",
        " saveMode=", cMpt.saveMode,
        " #gq=", cMpt.base.gq.len,
        " nForked=", mpt.nForked,
        " level=", mpt.level,
        "" # ' dmp

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
    let
      db = cMpt.base.parent
      mpt = cMpt.mpt
      rc = mpt.fetchPayload(cMpt.root, k)
    if rc.isOk:
      mpt.serialise(rc.value).toRc(db, info)
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
      mpt = cMpt.mpt
      rc = mpt.merge(cMpt.root, k, v)
    if rc.isErr:
      return err(rc.error.toError(db, info))
    ok()

  proc mptDelete(
      cMpt: AristoChildDbRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let
      db = cMpt.base.parent
      mpt = cMpt.mpt
      rc = mpt.delete(cMpt.root, k)
    if rc.isErr:
      return err(rc.error.toError(db, info))
    ok()

  proc mptHasPath(
      cMpt: AristoChildDbRef;
      key: openArray[byte];
      info: static[string];
        ): CoreDbRc[bool] =
    let
      db = cMpt.base.parent
      mpt = cMpt.mpt
      rc = mpt.hasPath(cMpt.root, key)
    if rc.isErr:
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

    rootVidFn: proc(): CoreDbVidRef =
      cMpt.rootVidFn(),

    isPruningFn: proc(): bool =
      true,

    persistentFn: proc(): CoreDbRc[void] =
      cMpt.mptPersistent("persistentFn()"),

    forgetFn: proc(): CoreDbRc[void] =
      cMpt.forget("forgetFn()"),

    pairsIt: iterator: (Blob,Blob) =
      for (k,v) in cMpt.mpt.right LeafTie(root: cMpt.root):
        yield (k.path.pathAsBlob, cMpt.mpt.serialise(v).valueOr(EmptyBlob)),

    replicateIt: iterator: (Blob,Blob) =
      discard)

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
    ok(base.mptCache)

  proc accFetch(
      cAcc: AristoChildDbRef;
      address: EthAddress;
      info: static[string];
        ): CoreDbRc[CoreDbAccount] =
    let
      db = cAcc.base.parent
      mpt = cAcc.mpt
      pyl = block:
        let
          key = address.keccakHash.data
          rc = mpt.fetchPayload(cAcc.root, key)
        if rc.isOk:
          rc.value
        elif rc.error[1] != FetchPathNotFound:
          return err(rc.error.toError(db, info))
        else:
          return err(rc.error.toError(db, info, AccNotFound))

    if pyl.pType != AccountData:
      let vePair = (pyl.account.storageID, PayloadTypeUnsupported)
      return err(vePair.toError(db, info & "/" & $pyl.pType))
    ok cAcc.toCoreDbAccount pyl.account

  proc accMerge(
      cAcc: AristoChildDbRef;
      address: EthAddress;
      acc: CoreDbAccount;
      info: static[string];
        ): CoreDbRc[void] =
    let
      db = cAcc.base.parent
      mpt = cAcc.mpt
      key = address.keccakHash.data
      val = acc.toPayloadRef()
      rc = mpt.merge(cAcc.root, key, val)
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
      mpt = cAcc.mpt
      key = address.keccakHash.data
      rc = mpt.delete(cAcc.root, key)
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
      mpt = cAcc.mpt
      key = address.keccakHash.data
      rc = mpt.hasPath(cAcc.root, key)
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

    mergeFn: proc(address: EthAddress; acc: CoreDbAccount): CoreDbRc[void] =
      cAcc.accMerge(address, acc, "mergeFn()"),

    hasPathFn: proc(address: EthAddress): CoreDbRc[bool] =
      cAcc.accHasPath(address, "hasPathFn()"),

    rootVidFn: proc(): CoreDbVidRef =
      cAcc.rootVidFn(),

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
    aVid:     e[0],
    aErr:     e[1]))

func toVoidRc*[T](
    rc: Result[T,AristoError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err((VertexID(0),rc.error).toError(db, info, error))


proc gc*(base: AristoBaseRef) =
  ## Run deferred destructors when it is safe. It is needed to run the
  ## destructors at the same scheduler level as the API call back functions.
  ## Any of the API functions can be intercepted by the `=destroy()` hook at
  ## inconvenient times so that atomicity would be violated if the actual
  ## destruction took place in `=destroy()`.
  ##
  ## Note: In practice the `db.gq` queue should not have much more than one
  ##       entry and mostly be empty.
  const info = "gc()"
  var adbAutoSave = false

  proc saveAndDestroy(cMpt: AristoChildDbRef): CoreDbRc[void] =
    if cMpt.mpt != base.adb:
      # FIXME: Currently no strategy for `Companion`
      cMpt.forget info
    elif cMpt.saveMode != AutoSave or adbAutoSave: # call only once:
      ok()
    else:
      adbAutoSave = true
      cMpt.persistent info

  if 0 < base.gq.len:
    # There might be a single queue item left over from the last run
    # which can be ignored right away as the body below would not change
    # anything.
    if base.gq.len != 1 or base.gq[0].mpt.level == 0:
      var later = AristoChildDbRef(nil)

      while 0 < base.gq.len:
        var q: seq[AristoChildDbRef]
        base.gq.swap q # now `=destroy()` may refill while destructing, below
        for cMpt in q:
          if noisy: echo "*** adb/gc (1)",
            " isAdb=", (cMpt.mpt == base.adb),
            " saveMode=", cMpt.saveMode,
            " nForked=", cMpt.mpt.nForked,
            " level=", cMpt.mpt.level,
            " #gq=", q.len
          if 0 < cMpt.mpt.level:
            assert cMpt.mpt == base.adb and cMpt.saveMode == AutoSave
            later = cMpt # do it later when there is no transaction pending
            continue
          cMpt.saveAndDestroy.isOkOr:
            debug logTxt info, saveMode=cMpt.saveMode, `error`=error.errorPrint
            continue # terminates `isOkOr()`

      # Re-add pending transaction item
      if not later.isNil:
        base.gq.add later
      if noisy: echo "*** adb/gc (2)", " #gq=", base.gq.len

# ---------------------

func mpt*(dsc: CoreDxMptRef): AristoDbRef =
  dsc.AristoCoreDxMptRef.ctx.mpt

func rootID*(dsc: CoreDxMptRef): VertexID  =
  dsc.AristoCoreDxMptRef.ctx.root

func txTop*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.adb.txTop.toRc(base.parent, info)

proc txBegin*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.adb.txBegin.toRc(base.parent, info)

# ---------------------

func getLevel*(base: AristoBaseRef): int =
  base.adb.level

proc getHash*(
    base: AristoBaseRef;
    vid: CoreDbVidRef;
    update: bool;
    info: static[string];
      ): CoreDbRc[Hash256] =
  let
    db = base.parent
    aVid = vid.to(VertexID)

  #const noisy = false
  if noisy:
    let mpt = vid.AristoCoreDbVid.ctx
    echo "*** adb/getHash (1)",
      " aVid=", aVid.pp(),
      " update=", update,
      " level=", mpt.level,
      " checkBE=", mpt.checkBE()

  if not aVid.isValid:
    if noisy: echo "*** adb/getHash (2) ok"
    return ok(EMPTY_ROOT_HASH)

  let mpt = vid.AristoCoreDbVid.ctx
  if update:
    var preState = ""
    if noisy:
      preState = mpt.pp(backendOk=false)

    let rc = mpt.hashify(noisy=noisy)

    if rc.isErr:
      if noisy: echo "*** adb/getHash (3)",
        " rc=", rc,
        " #gq=", base.gq.len,
        " nForked=", mpt.nForked,
        " level=", mpt.level,
        " check=",  mpt.checkBE(),
        "\n    preState\n    ", preState,
        "\n    db\n    " & mpt.pp(backendOk=false),
        "\n"
      return err(rc.error.toError(db, info, HashNotAvailable))
    # ? mpt.hashify.toVoidRc(db, info, HashNotAvailable)

  let key = block:
    let rc = mpt.getKeyRc aVid
    if rc.isErr:
      if noisy:
        let mpt = vid.AristoCoreDbVid.ctx
        echo "*** adb/getHash (8)",
          " aVid=", aVid.pp(),
          " error=", rc.error,
           "\n    state\n    ", mpt.pp()
      doAssert rc.error in {GetKeyNotFound,GetKeyUpdateNeeded}
      return err(rc.error.toError(db, info, HashNotAvailable))
    rc.value

  ok key.to(Hash256)


proc getVid*(
    base: AristoBaseRef;
    root: Hash256;
    createOk: bool;
    info: static[string];
      ): CoreDbRc[CoreDbVidRef] =
  let
    db = base.parent
    adb = base.adb
  base.gc() # update pending changes

  const noisy = false
  if noisy: echo "*** adb/getVid (1)",
    " root=", root.pp,
    " isEmpty=", root == EMPTY_ROOT_HASH,
    " createOk=", createOk

  if root == EMPTY_ROOT_HASH:
    return ok(db.bless AristoCoreDbVid(createOk: createOk))

  block:
    if noisy: echo "*** adb/getVid (2)"
    let rc = adb.hashify()
    if rc.isErr:
      if noisy: echo "*** adb/getVid (2.1)", " error=", rc.error
      return err(rc.error.toError(db, info, HashNotAvailable))
    # ? adb.hashify.toVoidRc(db, info, HashNotAvailable)

  # Check whether hash is available as state root on main trie
  block:
    if noisy: echo "*** adb/getVid (3)"
    let rc = adb.getKeyRc VertexID(1)
    if rc.isErr:
      if noisy: echo "*** adb/getVid (3.1)",
        " error=", rc.error,
        " #gq=", base.gq.len,
        " nForked=", adb.nForked,
        " level=", adb.level,
        "\n    db\n    " & adb.pp(backendOk=true)
      doAssert rc.error == GetKeyNotFound
    elif rc.value == root.to(HashKey):
      if noisy: echo "*** adb/getVid (3.2)"
      return ok(db.bless AristoCoreDbVid(aVid: VertexID(1), ctx: adb))
    else:
      if noisy: echo "*** adb/getVid (3.3)",
        " root=", root.pp,
        " value=", rc.value.pp
      discard

  # Check whether the `root` is avalilable in backlog
  block:
    # ..
    discard

  # Check whether the root vertex should be created
  if createOk:
    if noisy: echo "*** adb/getVid (8)"
    return ok(db.bless AristoCoreDbVid(createOk: true, expHash: root))

  if noisy: echo "*** adb/getVid (9)"
  err(aristo.GenericError.toError(db, info, RootNotFound))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc newMptHandler*(
    base: AristoBaseRef;
    root: CoreDbVidRef;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[CoreDxMptRef] =
  base.gc()

  let db = base.parent

  var rootID = root.to(VertexID)
  if not rootID.isValid:
    let rc = base.adb.getKeyRc VertexID(1)
    if rc.isErr:
      if rc.error != GetKeyNotFound:
        return err(rc.error.toError(db, info, RootNotFound))
      rootID = VertexID(1)

  let (mode, mpt) = case saveMode:
    of TopShot:
      (saveMode, ? base.adb.forkTop.toRc(db, info))
    of Companion:
      (saveMode, ? base.adb.fork.toRc(db, info))
    of Shared, AutoSave:
      if base.adb.backend.isNil:
        (Shared, base.adb)
      else:
        (saveMode, base.adb)

  if mode == Shared and rootID == VertexID(1):
    return ok(base.mptCache)

  let
    cMpt = AristoChildDbRef(
      base:     base,
      root:     rootID,
      mpt:      mpt,
      saveMode: mode,
      txError:  MptTxPending)

    dsc = AristoCoreDxMptRef(
      ctx:      cMpt,
      methods:  cMpt.mptMethods)

  ok(db.bless dsc)


proc newAccHandler*(
    base: AristoBaseRef;
    root: CoreDbVidRef;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[CoreDxAccRef] =
  base.gc()

  let db = base.parent

  if root.isValid:
    let vid = root.to(VertexID)
    if vid.isValid:
      if vid != VertexID(1):
        let error = (vid,AccountRootUnacceptable)
        return err(error.toError(db, info, RootUnacceptable))
    elif root.createOk:
      let error = AccountRootCannotCreate
      return err(error.toError(db, info, RootCannotCreate))

  let (mode, mpt) = case saveMode:
    of TopShot:
      (saveMode, ? base.adb.forkTop.toRc(db, info))
    of Companion:
      (saveMode, ? base.adb.fork.toRc(db, info))
    of Shared, AutoSave:
      if base.adb.backend.isNil:
        (Shared, base.adb)
      else:
        (saveMode, base.adb)

  if mode == Shared:
    return ok(base.accCache)

  let
    cAcc = AristoChildDbRef(
      base:     base,
      root:     VertexID(1),
      mpt:      mpt,
      saveMode: mode,
      txError:  AccTxPending)

    dsc = AristoCoreDxAccRef(
      ctx:      cAcc,
      methods:  cAcc.accMethods)

  ok(db.bless dsc)


proc destroy*(base: AristoBaseRef; flush: bool) =
  # Don't recycle pre-configured shared handler
  base.accCache.AristoCoreDxAccRef.ctx.mpt = AristoDbRef(nil)
  base.mptCache.AristoCoreDxMptRef.ctx.mpt = AristoDbRef(nil)

  # Clean up desctructor queue
  base.gc()

  # Close descriptor
  base.adb.finish(flush)


func init*(T: type AristoBaseRef; db: CoreDbRef; adb: AristoDbRef): T =
  result = T(parent: db, adb: adb)

  # Provide pre-configured handlers to share
  let
    cMpt = AristoChildDbRef(
      base:     result,
      root:     VertexID(1),
      mpt:      adb,
      saveMode: Shared,
      txError:  MptTxPending)

    cAcc = AristoChildDbRef(
      base:     result,
      root:     VertexID(1),
      mpt:      adb,
      saveMode: Shared,
      txError:  AccTxPending)

  result.mptCache = db.bless AristoCoreDxMptRef(
    ctx:      cMpt,
    methods:  cMpt.mptMethods)

  result.accCache = db.bless AristoCoreDxAccRef(
    ctx:      cAcc,
    methods:  cAcc.accMethods)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
