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
  ../../aristo as use_ari,
  ../../aristo/aristo_desc/desc_identifiers,
  ../../aristo/[aristo_init/memory_only, aristo_walk],
  ../../kvt as use_kvt,
  ../../kvt/[kvt_init/memory_only, kvt_walk],
  ../base/[base_config, base_desc, base_helpers]

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc create*(dbType: CoreDbType; kvt: KvtDbRef; mpt: AristoDbRef): CoreDbRef =
  ## Constructor helper
  var db = CoreDbRef(dbType: dbType)
  db.defCtx = db.bless CoreDbCtxRef(mpt: mpt, kvt: kvt)

  when CoreDbEnableApiJumpTable:
    db.kvtApi = KvtApiRef.init()
    db.ariApi = AristoApiRef.init()

  when CoreDbEnableProfiling:
    block:
      let profApi = KvtApiProfRef.init(db.kvtApi, kvt.backend)
      db.kvtApi = profApi
      kvt.backend = profApi.be
    block:
      let profApi = AristoApiProfRef.init(db.ariApi, mpt.backend)
      db.ariApi = profApi
      mpt.backend = profApi.be
  bless db

proc newAristoMemoryCoreDbRef*(): CoreDbRef =
  result = AristoDbMemory.create(
    KvtDbRef.init(use_kvt.MemBackendRef),
    AristoDbRef.init(use_ari.MemBackendRef))

proc newAristoVoidCoreDbRef*(): CoreDbRef =
  AristoDbVoid.create(
    KvtDbRef.init(use_kvt.VoidBackendRef),
    AristoDbRef.init(use_ari.VoidBackendRef))

proc newCtxByKey*(
    ctx: CoreDbCtxRef;
    key: Hash256;
    info: static[string];
      ): CoreDbRc[CoreDbCtxRef] =
  const
    rvid: RootedVertexID = (VertexID(1),VertexID(1))
  let
    db = ctx.parent

    # Find `(vid,key)` on transaction stack
    inx = block:
      let rc = db.ariApi.call(findTx, ctx.mpt, rvid, key.to(HashKey))
      if rc.isErr:
        return err(rc.error.toError info)
      rc.value

    # Fork MPT descriptor that provides `(vid,key)`
    newMpt = block:
      let rc = db.ariApi.call(forkTx, ctx.mpt, inx)
      if rc.isErr:
        return err(rc.error.toError info)
      rc.value

    # Fork KVT descriptor parallel to `newMpt`
    newKvt = block:
      let rc = db.kvtApi.call(forkTx, ctx.kvt, inx)
      if rc.isErr:
        discard db.ariApi.call(forget, newMpt)
        return err(rc.error.toError info)
      rc.value

  # Create new context
  ok(db.bless CoreDbCtxRef(kvt: newKvt, mpt: newMpt))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
