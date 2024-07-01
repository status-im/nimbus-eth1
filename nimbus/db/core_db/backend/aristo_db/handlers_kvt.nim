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
  eth/common,
  results,
  ../../../kvt as use_kvt,
  ../../base,
  ../../base/base_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toError(
    e: KvtError;
    base: CoreDbKvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, CoreDbErrorRef(
    ctx:      info,
    isAristo: false,
    kErr:     e))

func toRc[T](
    rc: Result[T,KvtError];
    base: CoreDbKvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err rc.error.toError(base, info, error)

# ------------------------------------------------------------------------------
# Private `kvt` call back functions
# ------------------------------------------------------------------------------

proc kvtMethods(): CoreDbKvtFns =
  ## Key-value database table handlers

  proc kvtBackend(
      cKvt:CoreDbKvtRef;
        ): CoreDbKvtBackendRef =
    cKvt.parent.bless CoreDbKvtBackendRef(kdb: cKvt.kvt)

  proc kvtForget(
      cKvt: CoreDbKvtRef;
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cKvt.parent.kdbBase
      kvt = cKvt.kvt
    if kvt != base.kdb:
      let rc = base.api.forget(kvt)

      # There is not much that can be done in case of a `forget()` error.
      # So unmark it anyway.
      cKvt.kvt = KvtDbRef(nil)

      if rc.isErr:
        return err(rc.error.toError(base, info))
    ok()

  proc kvtGet(
      cKvt: CoreDbKvtRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[Blob] =
    let
      base = cKvt.parent.kdbBase
      rc = base.api.get(cKvt.kvt, k)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError(base, info, KvtNotFound))
    else:
      rc.toRc(base, info)

  proc kvtLen(
      cKvt: CoreDbKvtRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[int] =
    let
      base = cKvt.parent.kdbBase
      rc = base.api.len(cKvt.kvt, k)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError(base, info, KvtNotFound))
    else:
      rc.toRc(base, info)

  proc kvtPut(
      cKvt: CoreDbKvtRef;
      k: openArray[byte];
      v: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cKvt.parent.kdbBase
      rc = base.api.put(cKvt.kvt, k, v)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(base, info))

  proc kvtDel(
      cKvt: CoreDbKvtRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[void] =
    let
      base = cKvt.parent.kdbBase
      rc = base.api.del(cKvt.kvt, k)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(base, info))

  proc kvtHasKey(
      cKvt: CoreDbKvtRef;
      k: openArray[byte];
      info: static[string];
        ): CoreDbRc[bool] =
    let
      base = cKvt.parent.kdbBase
      rc = base.api.hasKey(cKvt.kvt, k)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, info))

  CoreDbKvtFns(
    backendFn: proc(cKvt: CoreDbKvtRef): CoreDbKvtBackendRef =
      cKvt.kvtBackend(),

    getFn: proc(cKvt: CoreDbKvtRef; k: openArray[byte]): CoreDbRc[Blob] =
      cKvt.kvtGet(k, "getFn()"),

    lenFn: proc(cKvt: CoreDbKvtRef; k: openArray[byte]): CoreDbRc[int] =
      cKvt.kvtLen(k, "lenFn()"),

    delFn: proc(cKvt: CoreDbKvtRef; k: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtDel(k, "delFn()"),

    putFn: proc(cKvt: CoreDbKvtRef; k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      cKvt.kvtPut(k, v, "putFn()"),

    hasKeyFn: proc(cKvt: CoreDbKvtRef; k: openArray[byte]): CoreDbRc[bool] =
      cKvt.kvtHasKey(k, "hasKeyFn()"),

    forgetFn: proc(cKvt: CoreDbKvtRef): CoreDbRc[void] =
      cKvt.kvtForget("forgetFn()"))

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

func toVoidRc*[T](
    rc: Result[T,KvtError];
    base: CoreDbKvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isErr:
    return err(rc.error.toError(base, info, error))
  ok()

# ---------------------

proc txBegin*(
    base: CoreDbKvtBaseRef;
    info: static[string];
      ): KvtTxRef =
  let rc = base.api.txBegin(base.kdb)
  if rc.isErr:
    raiseAssert info & ": " & $rc.error
  rc.value

proc persistent*(
    base: CoreDbKvtBaseRef;
    info: static[string];
      ): CoreDbRc[void] =
  let
    api = base.api
    kvt = base.kdb
    rc = api.persist(kvt)
  if rc.isOk:
    ok()
  elif api.level(kvt) != 0:
    err(rc.error.toError(base, info, TxPending))
  elif rc.error == TxPersistDelayed:
    # This is OK: Piggybacking on `Aristo` backend
    ok()
  else:
    err(rc.error.toError(base, info))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc newKvtHandler*(
    base: CoreDbKvtBaseRef;
    info: static[string];
      ): CoreDbRc[CoreDbKvtRef] =
  ok(base.cache)


proc destroy*(base: CoreDbKvtBaseRef; eradicate: bool) =
  base.api.finish(base.kdb, eradicate)  # Close descriptor


func init*(T: type CoreDbKvtBaseRef; db: CoreDbRef; kdb: KvtDbRef): T =
  result = db.bless CoreDbKvtBaseRef(
    api:       KvtApiRef.init(),
    kdb:       kdb,

    # Preallocated shared descriptor
    cache: db.bless CoreDbKvtRef(
      kvt:     kdb,
      methods: kvtMethods()))

  when CoreDbEnableApiProfiling:
    let profApi = KvtApiProfRef.init(result.api, kdb.backend)
    result.api = profApi
    result.kdb.backend = profApi.be

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
