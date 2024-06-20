# nimbus-eth1
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Stackable API for `Kvt`
## =======================

import
  std/times,
  eth/common,
  results,
  ../aristo/aristo_profile,
  ./kvt_desc/desc_backend,
  ./kvt_init/memory_db,
  "."/[kvt_desc, kvt_init, kvt_tx, kvt_utils]

const
  AutoValidateApiHooks = defined(release).not
    ## No validatinon needed for production suite.

  KvtPersistentBackendOk = AutoValidateApiHooks # and false
    ## Set true for persistent backend profiling (which needs an extra
    ## link library.)

when KvtPersistentBackendOk:
  import ./kvt_init/rocks_db

# Annotation helper(s)
{.pragma: noRaise, gcsafe, raises: [].}

type
  KvtDbProfListRef* = AristoDbProfListRef
    ## Borrowed from `aristo_profile`

  KvtDbProfData* = AristoDbProfData
    ## Borrowed from `aristo_profile`

  KvtApiCommitFn* = proc(tx: KvtTxRef): Result[void,KvtError] {.noRaise.}
  KvtApiDelFn* = proc(db: KvtDbRef,
    key: openArray[byte]): Result[void,KvtError] {.noRaise.}
  KvtApiFinishFn* = proc(db: KvtDbRef, eradicate = false) {.noRaise.}
  KvtApiForgetFn* = proc(db: KvtDbRef): Result[void,KvtError] {.noRaise.}
  KvtApiForkTxFn* = proc(db: KvtDbRef,
    backLevel: int): Result[KvtDbRef,KvtError] {.noRaise.}
  KvtApiGetFn* = proc(db: KvtDbRef,
    key: openArray[byte]): Result[Blob,KvtError] {.noRaise.}
  KvtApiLenFn* = proc(db: KvtDbRef,
    key: openArray[byte]): Result[int,KvtError] {.noRaise.}
  KvtApiHasKeyFn* = proc(db: KvtDbRef,
    key: openArray[byte]): Result[bool,KvtError] {.noRaise.}
  KvtApiIsCentreFn* = proc(db: KvtDbRef): bool {.noRaise.}
  KvtApiIsTopFn* = proc(tx: KvtTxRef): bool {.noRaise.}
  KvtApiLevelFn* = proc(db: KvtDbRef): int {.noRaise.}
  KvtApiNForkedFn* = proc(db: KvtDbRef): int {.noRaise.}
  KvtApiPutFn* = proc(db: KvtDbRef,
    key, data: openArray[byte]): Result[void,KvtError] {.noRaise.}
  KvtApiReCentreFn* = proc(db: KvtDbRef): Result[void,KvtError] {.noRaise.}
  KvtApiRollbackFn* = proc(tx: KvtTxRef): Result[void,KvtError] {.noRaise.}
  KvtApiPersistFn* = proc(db: KvtDbRef): Result[void,KvtError] {.noRaise.}
  KvtApiToKvtDbRefFn* = proc(tx: KvtTxRef): KvtDbRef {.noRaise.}
  KvtApiTxBeginFn* = proc(db: KvtDbRef): Result[KvtTxRef,KvtError] {.noRaise.}
  KvtApiTxTopFn* =
    proc(db: KvtDbRef): Result[KvtTxRef,KvtError] {.noRaise.}

  KvtApiRef* = ref KvtApiObj
  KvtApiObj* = object of RootObj
    ## Useful set of `Kvt` fuctions that can be filtered, stacked etc. Note
    ## that this API is modelled after a subset of the `Aristo` API.
    commit*: KvtApiCommitFn
    del*: KvtApiDelFn
    finish*: KvtApiFinishFn
    forget*: KvtApiForgetFn
    forkTx*: KvtApiForkTxFn
    get*: KvtApiGetFn
    len*: KvtApiLenFn
    hasKey*: KvtApiHasKeyFn
    isCentre*: KvtApiIsCentreFn
    isTop*: KvtApiIsTopFn
    level*: KvtApiLevelFn
    nForked*: KvtApiNForkedFn
    put*: KvtApiPutFn
    reCentre*: KvtApiReCentreFn
    rollback*: KvtApiRollbackFn
    persist*: KvtApiPersistFn
    toKvtDbRef*: KvtApiToKvtDbRefFn
    txBegin*: KvtApiTxBeginFn
    txTop*: KvtApiTxTopFn


  KvtApiProfNames* = enum
    ## index/name mapping for profile slots
    KvtApiProfTotal          = "total"

    KvtApiProfCommitFn       = "commit"
    KvtApiProfDelFn          = "del"
    KvtApiProfFinishFn       = "finish"
    KvtApiProfForgetFn       = "forget"
    KvtApiProfForkTxFn       = "forkTx"
    KvtApiProfGetFn          = "get"
    KvtApiProfLenFn          = "len"
    KvtApiProfHasKeyFn       = "hasKey"
    KvtApiProfIsCentreFn     = "isCentre"
    KvtApiProfIsTopFn        = "isTop"
    KvtApiProfLevelFn        = "level"
    KvtApiProfNForkedFn      = "nForked"
    KvtApiProfPutFn          = "put"
    KvtApiProfReCentreFn     = "reCentre"
    KvtApiProfRollbackFn     = "rollback"
    KvtApiProfPersistFn      = "persist"
    KvtApiProfToKvtDbRefFn   = "toKvtDbRef"
    KvtApiProfTxBeginFn      = "txBegin"
    KvtApiProfTxTopFn        = "txTop"

    KvtApiProfBeGetKvpFn     = "be/getKvp"
    KvtApiProfBeLenKvpFn     = "be/lenKvp"
    KvtApiProfBePutKvpFn     = "be/putKvp"
    KvtApiProfBePutEndFn     = "be/putEnd"

  KvtApiProfRef* = ref object of KvtApiRef
    ## Profiling API extension of `KvtApiObj`
    data*: KvtDbProfListRef
    be*: BackendRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when AutoValidateApiHooks:
  proc validate(api: KvtApiObj|KvtApiRef) =
    doAssert not api.commit.isNil
    doAssert not api.del.isNil
    doAssert not api.finish.isNil
    doAssert not api.forget.isNil
    doAssert not api.forkTx.isNil
    doAssert not api.get.isNil
    doAssert not api.hasKey.isNil
    doAssert not api.isCentre.isNil
    doAssert not api.isTop.isNil
    doAssert not api.level.isNil
    doAssert not api.nForked.isNil
    doAssert not api.put.isNil
    doAssert not api.reCentre.isNil
    doAssert not api.rollback.isNil
    doAssert not api.persist.isNil
    doAssert not api.toKvtDbRef.isNil
    doAssert not api.txBegin.isNil
    doAssert not api.txTop.isNil

  proc validate(prf: KvtApiProfRef) =
    prf.KvtApiRef.validate
    doAssert not prf.data.isNil

proc dup(be: BackendRef): BackendRef =
  case be.kind:
  of BackendMemory:
    return MemBackendRef(be).dup

  of BackendRocksDB, BackendRdbTriggered:
    when KvtPersistentBackendOk:
      return RdbBackendRef(be).dup

  of BackendVoid:
    discard

# ------------------------------------------------------------------------------
# Public API constuctors
# ------------------------------------------------------------------------------

func init*(api: var KvtApiObj) =
  when AutoValidateApiHooks:
    api.reset
  api.commit = commit
  api.del = del
  api.finish = finish
  api.forget = forget
  api.forkTx = forkTx
  api.get = get
  api.len = len
  api.hasKey = hasKey
  api.isCentre = isCentre
  api.isTop = isTop
  api.level = level
  api.nForked = nForked
  api.put = put
  api.reCentre = reCentre
  api.rollback = rollback
  api.persist = persist
  api.toKvtDbRef = toKvtDbRef
  api.txBegin = txBegin
  api.txTop = txTop
  when AutoValidateApiHooks:
    api.validate

func init*(T: type KvtApiRef): T =
  result = new T
  result[].init()

func dup*(api: KvtApiRef): KvtApiRef =
  result = KvtApiRef(
    commit:     api.commit,
    del:        api.del,
    finish:     api.finish,
    forget:     api.forget,
    forkTx:     api.forkTx,
    get:        api.get,
    len:        api.len,
    hasKey:     api.hasKey,
    isCentre:   api.isCentre,
    isTop:      api.isTop,
    level:      api.level,
    nForked:    api.nForked,
    put:        api.put,
    reCentre:   api.reCentre,
    rollback:   api.rollback,
    persist:    api.persist,
    toKvtDbRef: api.toKvtDbRef,
    txBegin:    api.txBegin,
    txTop:      api.txTop)
  when AutoValidateApiHooks:
    api.validate

# ------------------------------------------------------------------------------
# Public profile API constuctor
# ------------------------------------------------------------------------------

func init*(
    T: type KvtApiProfRef;
    api: KvtApiRef;
    be = BackendRef(nil);
      ): T =
  ## This constructor creates a profiling API descriptor to be derived from
  ## an initialised `api` argument descriptor. For profiling the DB backend,
  ## the field `.be` of the result descriptor must be assigned to the
  ## `.backend` field of the `KvtDbRef` descriptor.
  ##
  ## The argument desctiptors `api` and `be` will not be modified and can be
  ## used to restore the previous set up.
  ##
  let
    data = KvtDbProfListRef(
      list: newSeq[KvtDbProfData](1 + high(KvtApiProfNames).ord))
    profApi = T(data: data)

  template profileRunner(n: KvtApiProfNames, code: untyped): untyped =
    let start = getTime()
    code
    data.update(n.ord, getTime() - start)

  profApi.commit =
    proc(a: KvtTxRef): auto =
      KvtApiProfCommitFn.profileRunner:
        result = api.commit(a)

  profApi.del =
    proc(a: KvtDbRef; b: openArray[byte]): auto =
      KvtApiProfDelFn.profileRunner:
        result = api.del(a, b)

  profApi.finish =
    proc(a: KvtDbRef; b = false) =
      KvtApiProfFinishFn.profileRunner:
        api.finish(a, b)

  profApi.forget =
    proc(a: KvtDbRef): auto =
      KvtApiProfForgetFn.profileRunner:
        result = api.forget(a)

  profApi.forkTx =
    proc(a: KvtDbRef, b: int): auto =
      KvtApiProfForkTxFn.profileRunner:
        result = api.forkTx(a, b)

  profApi.get =
    proc(a: KvtDbRef, b: openArray[byte]): auto =
      KvtApiProfGetFn.profileRunner:
        result = api.get(a, b)

  profApi.len =
    proc(a: KvtDbRef, b: openArray[byte]): auto =
      KvtApiProfLenFn.profileRunner:
        result = api.len(a, b)

  profApi.hasKey =
    proc(a: KvtDbRef, b: openArray[byte]): auto =
      KvtApiProfHasKeyFn.profileRunner:
        result = api.hasKey(a, b)

  profApi.isCentre =
    proc(a: KvtDbRef): auto =
      KvtApiProfIsCentreFn.profileRunner:
        result = api.isCentre(a)

  profApi.isTop =
    proc(a: KvtTxRef): auto =
      KvtApiProfIsTopFn.profileRunner:
        result = api.isTop(a)

  profApi.level =
    proc(a: KvtDbRef): auto =
      KvtApiProfLevelFn.profileRunner:
        result = api.level(a)

  profApi.nForked =
    proc(a: KvtDbRef): auto =
      KvtApiProfNForkedFn.profileRunner:
        result = api.nForked(a)

  profApi.put =
    proc(a: KvtDbRef; b, c: openArray[byte]): auto =
      KvtApiProfPutFn.profileRunner:
        result = api.put(a, b, c)

  profApi.reCentre =
    proc(a: KvtDbRef): auto =
      KvtApiProfReCentreFn.profileRunner:
        result = api.reCentre(a)

  profApi.rollback =
    proc(a: KvtTxRef): auto =
      KvtApiProfRollbackFn.profileRunner:
        result = api.rollback(a)

  profApi.persist =
    proc(a: KvtDbRef): auto =
      KvtApiProfPersistFn.profileRunner:
        result = api.persist(a)

  profApi.toKvtDbRef =
     proc(a: KvtTxRef): auto =
       KvtApiProfToKvtDbRefFn.profileRunner:
         result = api.toKvtDbRef(a)

  profApi.txBegin =
    proc(a: KvtDbRef): auto =
      KvtApiProfTxBeginFn.profileRunner:
        result = api.txBegin(a)

  profApi.txTop =
    proc(a: KvtDbRef): auto =
      KvtApiProfTxTopFn.profileRunner:
        result = api.txTop(a)

  let beDup = be.dup()
  if beDup.isNil:
    profApi.be = be

  else:
    beDup.getKvpFn =
      proc(a: openArray[byte]): auto =
        KvtApiProfBeGetKvpFn.profileRunner:
          result = be.getKvpFn(a)
    data.list[KvtApiProfBeGetKvpFn.ord].masked = true

    beDup.lenKvpFn =
      proc(a: openArray[byte]): auto =
        KvtApiProfBeLenKvpFn.profileRunner:
          result = be.lenKvpFn(a)
    data.list[KvtApiProfBeLenKvpFn.ord].masked = true

    beDup.putKvpFn =
      proc(a: PutHdlRef; b: openArray[(Blob,Blob)]) =
        be.putKvpFn(a,b)
    data.list[KvtApiProfBePutKvpFn.ord].masked = true

    beDup.putEndFn =
      proc(a: PutHdlRef): auto =
        KvtApiProfBePutEndFn.profileRunner:
          result = be.putEndFn(a)
    data.list[KvtApiProfBePutEndFn.ord].masked = true

    profApi.be = beDup

  when AutoValidateApiHooks:
    profApi.validate

  profApi

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
