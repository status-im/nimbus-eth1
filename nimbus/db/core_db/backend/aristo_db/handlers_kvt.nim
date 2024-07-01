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

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

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
      kvt:     kdb))

  when CoreDbEnableApiProfiling:
    let profApi = KvtApiProfRef.init(result.api, kdb.backend)
    result.api = profApi
    result.kdb.backend = profApi.be

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
