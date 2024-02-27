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
  chronicles,
  eth/common,
  results,
  ../../../kvt,
  ../../../kvt/[kvt_desc, kvt_init, kvt_utils, kvt_tx],
  ../../base,
  ../../base/base_desc,
  ./common_desc

type
  KvtBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    kdb: KvtDbRef                ## Key-value table
    gq: seq[KvtChildDbRef]       ## Garbage queue, deferred disposal
    cache: CoreDxKvtRef          ## Pre-configured descriptor to share

  KvtChildDbRef = ref KvtChildDbObj
  KvtChildDbObj = object
    ## Sub-handle for triggering destructor when it goes out of scope
    base: KvtBaseRef             ## Local base descriptor
    kvt: KvtDbRef                ## Descriptor
    saveMode: CoreDbSaveFlags    ## When to store/discard

  KvtCoreDxKvtRef = ref object of CoreDxKvtRef
    ## Some extendion to recover embedded state
    ctx: KvtChildDbRef           ## Embedded state, typical var name: `cKvt`

  AristoCoreDbKvtBE* = ref object of CoreDbKvtBackendRef
    kdb*: KvtDbRef

logScope:
  topics = "kvt-hdl"

proc gc*(base: KvtBaseRef) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb/kdb " & info

# -------------------------------

func toError(
    e: KvtError;
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  db.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: false,
    kErr:     e))

func toRc[T](
    rc: Result[T,KvtError];
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

# ------------------------------------------------------------------------------
# Private auto destructor
# ------------------------------------------------------------------------------

proc `=destroy`(cKvt: var KvtChildDbObj) =
  ## Auto destructor
  let
    base = cKvt.base
    kvt = cKvt.kvt
  if not kvt.isNil:
    block body:
      # Do some heuristics to avoid duplicates:
      block addToBatchQueue:
        if kvt != base.kdb:              # not base descriptor?
          if kvt.level == 0:             # no transaction pending?
            break addToBatchQueue        # add to destructor queue
          else:
            break body                   # ignore `kvt`

        if cKvt.saveMode != AutoSave:    # is base descriptor, no auto-save?
          break body                     # ignore `kvt`

        if base.gq.len == 0:             # empty batch queue?
          break addToBatchQueue          # add to destructor queue

        if base.gq[0].kvt == kvt or      # not the same as first entry?
           base.gq[^1].kvt == kvt:       # not the same as last entry?
          break body                     # ignore `kvt`

      # Add to destructor batch queue. Note that the `adb` destructor might
      # have a pending transaction which might be resolved while queued for
      # persistent saving.
      base.gq.add KvtChildDbRef(
        base:     base,
        kvt:      kvt,
        saveMode: cKvt.saveMode)

      # End body

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc persistent(
    cKvt: KvtChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    base = cKvt.base
    kvt = cKvt.kvt
    db = base.parent
    rc = kvt.stow()

  # Note that `gc()` may call `persistent()` so there is no `base.gc()` here
  if rc.isOk:
    ok()
  elif kvt.level == 0:
    err(rc.error.toError(db, info))
  else:
    err(rc.error.toError(db, info, KvtTxPending))

proc forget(
    cKvt: KvtChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    base = cKvt.base
    kvt = cKvt.kvt
  cKvt.kvt = KvtDbRef(nil) # Disables `=destroy()` action
  base.gc()
  result = ok()

  if kvt != base.kdb:
    let
      db = base.parent
      rc = kvt.forget()
    if rc.isErr:
      result = err(rc.error.toError(db, info))

# ------------------------------------------------------------------------------
# Private `kvt` call back functions
# ------------------------------------------------------------------------------

proc kvtMethods(cKvt: KvtChildDbRef): CoreDbKvtFns =
  ## Key-value database table handlers

  proc kvtBackend(
      cKvt: KvtChildDbRef;
        ): CoreDbKvtBackendRef =
    let
      db = cKvt.base.parent
      kvt = cKvt.kvt
    db.bless AristoCoreDbKvtBE(kdb: kvt)

  proc kvtPersistent(
    cKvt: KvtChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
    cKvt.base.gc()
    cKvt.persistent info # note that `gc()` calls `persistent()`

  proc kvtGet(
      cKvt: KvtChildDbRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[Blob] =
    ## Member of `CoreDbKvtFns`
    let rc = cKvt.kvt.get(k)
    if rc.isErr:
      let db = cKvt.base.parent
      if rc.error == GetNotFound:
        return err(rc.error.toError(db, info, KvtNotFound))
      else:
        return rc.toRc(db, info)
    ok(rc.value)

  proc kvtPut(
      cKvt: KvtChildDbRef;
      k: openArray[byte];
      v: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let rc = cKvt.kvt.put(k,v)
    if rc.isErr:
      return err(rc.error.toError(cKvt.base.parent, info))
    ok()

  proc kvtDel(
      cKvt: KvtChildDbRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let rc = cKvt.kvt.del k
    if rc.isErr:
      return err(rc.error.toError(cKvt.base.parent, info))
    ok()

  proc kvtHasKey(
      cKvt: KvtChildDbRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[bool] =
    let rc = cKvt.kvt.hasKey(k)
    if rc.isErr:
      return err(rc.error.toError(cKvt.base.parent, info))
    ok(rc.value)

  CoreDbKvtFns(
    backendFn: proc(): CoreDbKvtBackendRef =
      cKvt.kvtBackend(),

    getFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      cKvt.kvtGet(k, "getFn()"),

    delFn: proc(k: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtDel(k, "delFn()"),

    putFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtPut(k, v, "putFn()"),

    hasKeyFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      cKvt.kvtHasKey(k, "hasKeyFn()"),

    persistentFn: proc(): CoreDbRc[void] =
      cKvt.kvtPersistent("persistentFn()"),

    forgetFn: proc(): CoreDbRc[void] =
      cKvt.forget("forgetFn()"))

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

func toVoidRc*[T](
    rc: Result[T,KvtError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isErr:
    return err(rc.error.toError(db, info, error))
  ok()


proc gc*(base: KvtBaseRef) =
  ## Run deferred destructors when it is safe. It is needed to run the
  ## destructors at the same scheduler level as the API call back functions.
  ## Any of the API functions can be intercepted by the `=destroy()` hook at
  ## inconvenient times so that atomicity would be violated if the actual
  ## destruction took place in `=destroy()`.
  ##
  ## Note: In practice the garbage queue should not have much more than one
  ##       entry and mostly be empty.
  const info = "gc()"
  var kdbAutoSave = false

  proc saveAndDestroy(cKvt: KvtChildDbRef): CoreDbRc[void] =
    if cKvt.kvt != base.kdb:
      # FIXME: Currently no strategy for `Companion`
      cKvt.forget info
    elif cKvt.saveMode != AutoSave or kdbAutoSave: # call only once
      ok()
    else:
      kdbAutoSave = true
      cKvt.persistent info

  if 0 < base.gq.len:
    # There might be a single queue item left over from the last run
    # which can be ignored right away as the body below would not change
    # anything.
    if base.gq.len != 1 or base.gq[0].kvt.level == 0:
      var later = KvtChildDbRef(nil)

      while 0 < base.gq.len:
        var q: seq[KvtChildDbRef]
        base.gq.swap q # now `=destroy()` may refill while destructing, below
        for cKvt in q:
          if 0 < cKvt.kvt.level:
            assert cKvt.kvt == base.kdb and cKvt.saveMode == AutoSave
            later = cKvt # do it later when no transaction pending
            continue
          cKvt.saveAndDestroy.isOkOr:
            debug logTxt info, saveMode=cKvt.saveMode, `error`=error.errorPrint
            continue # terminates `isOkOr()`

      # Re-add pending transaction item
      if not later.isNil:
        base.gq.add later

# ---------------------

func to*(dsc: CoreDxKvtRef; T: type KvtDbRef): T =
  KvtCoreDxKvtRef(dsc).ctx.kvt

func txTop*(
    base: KvtBaseRef;
    info: static[string];
      ): CoreDbRc[KvtTxRef] =
  base.kdb.txTop.toRc(base.parent, info)

proc txBegin*(
    base: KvtBaseRef;
    info: static[string];
      ): CoreDbRc[KvtTxRef] =
  base.kdb.txBegin.toRc(base.parent, info)

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc newKvtHandler*(
    base: KvtBaseRef;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[CoreDxKvtRef] =
  base.gc()

  let
    db = base.parent

    (mode, kvt) = case saveMode:
      of TopShot:
        (saveMode, ? base.kdb.forkTop.toRc(db, info))
      of Companion:
        (saveMode, ? base.kdb.fork.toRc(db, info))
      of Shared, AutoSave:
        if base.kdb.backend.isNil:
          (Shared, base.kdb)
        else:
          (saveMode, base.kdb)

  if mode == Shared:
    return ok(base.cache)

  let
    cKvt = KvtChildDbRef(
      base:     base,
      kvt:      kvt,
      saveMode: mode)

    dsc = KvtCoreDxKvtRef(
      ctx:      cKvt,
      methods:  cKvt.kvtMethods)

  ok(db.bless dsc)


proc destroy*(base: KvtBaseRef; flush: bool) =
  # Don't recycle pre-configured shared handler
  base.cache.KvtCoreDxKvtRef.ctx.kvt = KvtDbRef(nil)

  # Clean up desctructor queue
  base.gc()

  # Close descriptor
  base.kdb.finish(flush)


func init*(T: type KvtBaseRef; db: CoreDbRef; kdb: KvtDbRef): T =
  result = T(parent: db, kdb: kdb)

  # Provide pre-configured handlers to share
  let cKvt = KvtChildDbRef(
    base:     result,
    kvt:      kdb,
    saveMode: Shared)

  result.cache = db.bless KvtCoreDxKvtRef(
    ctx:      cKvt,
    methods:  cKvt.kvtMethods)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
