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
  ../../../kvt,
  ../../../kvt/kvt_desc,
  ../../base,
  ../../base/base_desc,
  ./common_desc

type
  KvtBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    kdb: KvtDbRef                ## Key-value table
    gq: seq[KvtChildDbRef]       ## Garbage queue, deferred disposal

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

func toErrorImpl(
    e: KvtError;
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  db.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: false,
    kErr:     e))

func toRcImpl[T](
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
  err rc.error.toErrorImpl(db, info, error)

# ------------------------------------------------------------------------------
# Private call back functions  (too large for keeping inline)
# ------------------------------------------------------------------------------

proc finish(
    cKvt: KvtChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
  ## key-value table destructor to be called automagically when the argument
  ## wrapper gets out of scope
  let
    base = cKvt.base
    db = base.parent

  result = ok()

  if cKvt.kvt != base.kdb:
    let rc = cKvt.kvt.forget()
    if rc.isErr:
      result = err(rc.error.toErrorImpl(db, info))
    cKvt.kvt = KvtDbRef(nil) # Disables `=destroy()` action

  if cKvt.saveMode == AutoSave:
    if base.kdb.level == 0:
      let rc = base.kdb.stow()
      if rc.isErr:
        result = err(rc.error.toErrorImpl(db, info))

proc `=destroy`(cKvt: var KvtChildDbObj) =
  ## Auto destructor
  if not cKvt.kvt.isNil:
    # Add to destructor batch queue unless direct reference
    if cKvt.kvt != cKvt.base.kdb or
       cKvt.saveMode == AutoSave:
      cKvt.base.gq.add KvtChildDbRef(
        base:     cKvt.base,
        kvt:      cKvt.kvt,
        saveMode: cKvt.saveMode)

# -------------------------------

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
      return err(rc.error.toErrorImpl(db, info, KvtNotFound))
    else:
      return rc.toRcImpl(db, info)
  ok(rc.value)

proc kvtPut(
    cKvt: KvtChildDbRef;
    k: openArray[byte];
    v: openArray[byte];
    info: static[string];
      ): CoreDbRc[void] =
  let rc = cKvt.kvt.put(k,v)
  if rc.isErr:
    return err(rc.error.toErrorImpl(cKvt.base.parent, info))
  ok()

proc kvtDel(
    cKvt: KvtChildDbRef;
    k: openArray[byte];
    info: static[string];
      ): CoreDbRc[void] =
  let rc = cKvt.kvt.del k
  if rc.isErr:
    return err(rc.error.toErrorImpl(cKvt.base.parent, info))
  ok()

proc kvtHasKey(
    cKvt: KvtChildDbRef;
    k: openArray[byte];
    info: static[string];
      ): CoreDbRc[bool] =
  cKvt.kvt.hasKey(k).toRcImpl(cKvt.base.parent, info)

# ------------------------------------------------------------------------------
# Private database methods function table
# ------------------------------------------------------------------------------

proc kvtMethods(cKvt: KvtChildDbRef): CoreDbKvtFns =
  ## Key-value database table handlers
  let db = cKvt.base.parent
  CoreDbKvtFns(
    backendFn: proc(): CoreDbKvtBackendRef =
      db.bless(AristoCoreDbKvtBE(kdb: cKvt.kvt)),

    getFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      cKvt.kvtGet(k, "getFn()"),

    delFn: proc(k: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtDel(k, "delFn()"),

    putFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtPut(k, v, "putFn()"),

    hasKeyFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      cKvt.kvtHasKey(k, "hasKeyFn()"),

    destroyFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[void] =
      cKvt.base.gc()
      cKvt.finish("destroyFn()"),

    pairsIt: iterator(): (Blob, Blob) =
      discard)

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

func toVoidRc*[T](
    rc: Result[T,KvtError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err rc.error.toErrorImpl(db, info, error)

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
  while 0 < base.gq.len:
    var q: typeof base.gq
    base.gq.swap q # now `=destroy()` may refill while destructing, below
    for cKvt in q:
      cKvt.finish(info).isOkOr:
        debug logTxt info, `error`=error.errorPrint
        continue # terminates `isOkOr()`

func kvt*(dsc: CoreDxKvtRef): KvtDbRef =
  dsc.KvtCoreDxKvtRef.ctx.kvt

# ---------------------

func txTop*(
    base: KvtBaseRef;
    info: static[string];
      ): CoreDbRc[KvtTxRef] =
  base.kdb.txTop.toRcImpl(base.parent, info)

func txBegin*(
    base: KvtBaseRef;
    info: static[string];
      ): CoreDbRc[KvtTxRef] =
  base.kdb.txBegin.toRcImpl(base.parent, info)

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

    (mode, kvt) = block:
      if saveMode == Companion:
        (saveMode, ? base.kdb.forkTop.toRcImpl(db, info))
      elif base.kdb.backend.isNil:
        (Cached, base.kdb)
      else:
        (saveMode, base.kdb)

    cKvt = KvtChildDbRef(
      base:     base,
      kvt:      kvt,
      saveMode: mode)

    dsc = KvtCoreDxKvtRef(
      ctx:      cKvt,
      methods:  cKvt.kvtMethods)

  ok(db.bless dsc)


proc destroy*(base: KvtBaseRef; flush: bool) =
  base.gc()
  base.kdb.finish(flush)

func init*(T: type KvtBaseRef; db: CoreDbRef; kdb: KvtDbRef): T =
  T(parent: db, kdb: kdb)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
