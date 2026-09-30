# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/os,
  tempfile,
  unittest2,
  rocksdb,
  stew/endians2,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_blobify, aristo_constants, aristo_desc],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/
    [rdb_desc, rdb_get, rdb_init, rdb_put],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  bigVid = VertexID(1'u64 shl 48)
  maxPackedVid = VertexID((1'u64 shl 48) - 1)

proc makeHashKey(i: uint64): HashKey =
  var hash: Hash32
  hash.data()[0 .. 7] = i.toBytesBE()
  hash.to(HashKey)

proc openTestBaseDb(basePath: string, opts: DbOptions): RocksDbInstanceRef =
  let cache = cacheCreateLRU(opts.blockCacheSize, autoClose = true)
  RocksDbInstanceRef
    .open(basePath, opts.toDbOpts(), @[($VtxCF, opts.toCfOpts(cache, true))], wipe = true)
    .expect("open test RocksDB")

suite "Aristo rdb branch cache value":
  test "Branch value round trip":
    for (vid, used) in [
      (VertexID(0), 0'u16),
      (VertexID(0), 0xFFFF'u16),
      (VertexID(FIRST_DYNAMIC_VID), 0x8001'u16),
      (maxPackedVid, 0'u16),
      (maxPackedVid, 0xFFFF'u16),
    ]:
      let vtx = BranchRef.init(vid, used)
      check:
        vtx.fitsBranchVal()
        vtx.toBranchVal().startVid == vid
        vtx.toBranchVal().used == used

  test "Branch value beyond 48 bits is not cacheable":
    check:
      not BranchRef.init(bigVid, 0).fitsBranchVal()
      not BranchRef.init(VertexID(uint64.high), 0xFFFF).fitsBranchVal()

  test "Branches with a startVid beyond 48 bits go to the vertex cache":
    let
      basePath = mkdtemp(prefix = "rdb_branch_val_", dir = getAppDir())
      opts = DbOptions.init(
        maxOpenFiles = 32,
        writeBufferSize = 1024 * 1024,
        rowCacheSize = 0,
        blockCacheSize = 8 * 1024 * 1024,
        rdbVtxCacheSize = 1024 * 1024,
        rdbKeyCacheSize = 1024 * 1024,
        rdbBranchCacheSize = 1024 * 1024,
        maxSnapshots = 2,
      )
    defer:
      try:
        removeDir(basePath)
      except CatchableError:
        discard

    var rdb: RdbInst
    rdb.init(opts, openTestBaseDb(basePath, opts))
    defer:
      rdb.close(wipe = true)

    let
      smallBranch = (STATE_ROOT_VID, VertexID(2))
      bigStartBranch = (STATE_ROOT_VID, VertexID(3))

    block:
      let session = rdb.begin()
      check:
        rdb.putVtx(
          session,
          smallBranch,
          VertexRef(BranchRef.init(VertexID(FIRST_DYNAMIC_VID + 16), 0x00ff'u16)),
          makeHashKey(1),
        ).isOk()
        rdb.putVtx(
          session, bigStartBranch, VertexRef(BranchRef.init(bigVid, 0xffff'u16)), makeHashKey(2)
        ).isOk()
        rdb.commit(session).isOk()

    check:
      rdb.rdBranchLru.len == 1
      rdb.rdVtxLru.len == 1

    for flags in [default(set[GetVtxFlag]), {GetVtxFlag.PeekCache}]:
      let vtx = rdb.getVtx(bigStartBranch, flags).expect("getVtx")
      check:
        vtx.vType == Branch
        BranchRef(vtx).startVid == bigVid
        BranchRef(vtx).used == 0xffff'u16

      let small = rdb.getVtx(smallBranch, flags).expect("getVtx")
      check:
        BranchRef(small).startVid == VertexID(FIRST_DYNAMIC_VID + 16)
        BranchRef(small).used == 0x00ff'u16

    block:
      rdb.rdVtxLru.del(bigStartBranch)
      check rdb.rdVtxLru.len == 0

      let vtx = rdb.getVtx(bigStartBranch, {}).expect("getVtx")
      check:
        BranchRef(vtx).startVid == bigVid
        rdb.rdBranchLru.len == 1
        rdb.rdVtxLru.len == 1
