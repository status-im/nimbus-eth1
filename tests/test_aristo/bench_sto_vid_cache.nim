# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Benchmark for the storage leaf vid cache (`AristoDbRef.stoLeafVids`).
##
## One account is given a large storage trie so that a cold slot read has a real
## root-to-leaf descent to perform, and the payload cache (`stoLeaves`) is then
## deliberately sized well below the working set so that most reads miss it. That
## is the only situation the vid cache is meant to help with - when `stoLeaves`
## covers the working set it answers everything itself and the vid cache is never
## consulted.
##
## Three configurations are compared:
##
## * `payload only` - vid cache disabled, i.e. the behaviour before it existed
## * `payload + vid` - the same payload cache plus a vid cache
## * `bigger payload` - no vid cache, but the payload cache grown by the same
##   number of *bytes* the vid cache would have used
##
## The third one is the comparison that actually decides whether the vid cache
## earns its memory: spending those bytes on more payload entries instead is
## always an option, and a vid entry only avoids the descent while a payload
## entry avoids the whole read.
##
## Each is run twice: against the in-memory backend, which isolates the CPU cost
## of the vertex lookups that are skipped, and against a real RocksDB backend,
## which is the number that actually matters. The in-memory figures are the more
## flattering of the two because that backend copies a `seq[byte]` and deblobifies
## on every vertex lookup with no LRU in front of it.
##
## `slotCount` and `readCount` are `-d:` overridable, e.g.
## `-d:slotCount=1200000`. Size matters a great deal to the outcome: the vid cache
## makes a cold read roughly independent of trie depth, so its advantage over
## simply growing the payload cache widens as the storage trie grows.

{.used.}

import
  std/[atomics, os, strformat, strutils, times],
  tempfile,
  unittest2,
  rocksdb,
  results,
  eth/common/hashes,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[
    aristo_desc,
    aristo_fetch,
    aristo_merge,
    aristo_tx_frame,
    aristo_init/init_common,
    aristo_init/memory_only,
    aristo_init/rocks_db,
  ],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/rdb_desc,
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  slotCount {.intdefine.} = 150_000
    ## Storage slots on the one account. Sets the depth of the trie that a cold
    ## read has to descend: roughly log16(slotCount) levels.
  readCount {.intdefine.} = 300_000
  payloadCacheSize = slotCount div 8
    ## Small enough that the great majority of reads miss it.
  vidCacheSize = slotCount
    ## Large enough to cover everything the payload cache spills.
  nameWidth = 16

type Stats = object
  name: string
  elapsed: float
  hits, stale, misses: int
  payloadLen, vidLen: int

func splitmix64(x: uint64): uint64 =
  var z = x + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc makePath(i: uint64): Hash32 =
  ## A well-spread path, standing in for the keccak digest that a real slot key
  ## would be. A sequential path would give a degenerate trie shape.
  for w in 0 ..< 4:
    let v = splitmix64(i * 4 + w.uint64)
    for b in 0 ..< 8:
      result.data()[w * 8 + b] = byte((v shr (b * 8)) and 0xff)

proc makeReadOrder(): seq[int] =
  result = newSeq[int](readCount)
  for i in 0 ..< readCount:
    result[i] = int(splitmix64(uint64(i)) mod slotCount.uint64)

proc runConfig(
    db: AristoDbRef;
    name: string;
    accPath: Hash32;
    slots: openArray[Hash32];
    readOrder: openArray[int];
    payloadSize, vidSize: int;
): Stats =
  # Re-open so the previous configuration's caches and frame state are gone and
  # every read has to go through the caches into the backend.
  db.close()
  db.initInstance(
    accLeavesLruSize = 1024,
    stoLeavesLruSize = payloadSize,
    stoLeafVidsLruSize = vidSize,
    parallelStateRootComputation = false,
  ).expect("re-init instance")

  let tx = db.baseTxFrame()

  # Warm up: one pass over every slot, which fills the payload cache and spills
  # the overflow into the vid cache.
  for slot in slots:
    doAssert tx.fetchSlot(accPath, slot).isOk()

  let
    hits0 = db.stoVidHits.load(moRelaxed)
    stale0 = db.stoVidStale.load(moRelaxed)
    misses0 = db.stoVidMisses.load(moRelaxed)

  var checksum = 0'u64
  let started = epochTime()
  for index in readOrder:
    checksum += tx.fetchSlot(accPath, slots[index]).expect("bench").truncate(uint64)
  let elapsed = epochTime() - started

  doAssert checksum != 0

  Stats(
    name: name,
    elapsed: elapsed,
    hits: db.stoVidHits.load(moRelaxed) - hits0,
    stale: db.stoVidStale.load(moRelaxed) - stale0,
    misses: db.stoVidMisses.load(moRelaxed) - misses0,
    payloadLen: db.stoLeaves.len,
    vidLen: db.stoLeafVids.len,
  )

proc line(s: Stats, baseline: float): string =
  let
    perRead = (s.elapsed * 1_000_000.0) / readCount.float
    speedup = baseline / s.elapsed
  "  " & alignLeft(s.name, nameWidth) & align(fmt"{s.elapsed:.3f}", 9) &
    align(fmt"{perRead:.3f}", 10) & align(fmt"{speedup:.2f}x", 9) &
    align($s.hits, 11) & align($s.stale, 8) & align($s.misses, 11)

suite "Aristo storage leaf vid cache benchmark":
  test "cold slot reads with a payload cache smaller than the working set":
    let db = AristoDbRef.init()
    db.parallelStateRootComputation = false

    let accPath = makePath(0xACC0'u64)
    var slots = newSeq[Hash32](slotCount)

    block seed:
      let wtx = db.txFrameBegin(db.baseTxFrame())
      doAssert wtx.mergeAccount(
        accPath, AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH)).isOk()
      for i in 0 ..< slotCount:
        slots[i] = makePath(uint64(i) + 1)
        doAssert wtx.mergeSlot(accPath, slots[i], (i + 1).u256).isOk()

      wtx.checkpoint(1, skipSnapshot = true)
      let batch = db.putBegFn().expect("working batch")
      db.persist(batch, wtx)
      doAssert db.putEndFn(batch).isOk()

    let readOrder = makeReadOrder()

    # Size the payload-only alternative so it uses the same number of bytes the
    # vid cache would have. Both caches carry ~8 bytes of intrusive list links
    # plus their key and value, so compare on that basis.
    const
      payloadEntryBytes = 8 + sizeof(Hash32) + sizeof(CachedStoLeaf)
      vidEntryBytes = 8 + sizeof(uint64) + sizeof(VertexID)
      grownPayloadSize =
        payloadCacheSize + (vidCacheSize * vidEntryBytes) div payloadEntryBytes

    let
      payloadOnly = db.runConfig(
        "payload only", accPath, slots, readOrder, payloadCacheSize, 0)
      payloadAndVid = db.runConfig(
        "payload + vid", accPath, slots, readOrder, payloadCacheSize, vidCacheSize)
      biggerPayload = db.runConfig(
        "bigger payload", accPath, slots, readOrder, grownPayloadSize, 0)

    debugEcho ""
    debugEcho "Aristo storage leaf vid cache benchmark"
    debugEcho "  slots seeded:        ", slotCount
    debugEcho "  reads timed:         ", readCount
    debugEcho "  payload cache:       ", payloadCacheSize, " entries @ ",
      payloadEntryBytes, " B = ", (payloadCacheSize * payloadEntryBytes) shr 20, " MiB"
    debugEcho "  vid cache:           ", vidCacheSize, " entries @ ",
      vidEntryBytes, " B = ", (vidCacheSize * vidEntryBytes) shr 20, " MiB"
    debugEcho "  grown payload cache: ", grownPayloadSize, " entries = ",
      (grownPayloadSize * payloadEntryBytes) shr 20, " MiB (same total bytes)"
    debugEcho ""
    debugEcho "  " & alignLeft("config", nameWidth) & align("secs", 9) &
      align("us/read", 10) & align("speedup", 9) & align("vid hits", 11) &
      align("stale", 8) & align("vid miss", 11)
    debugEcho line(payloadOnly, payloadOnly.elapsed)
    debugEcho line(payloadAndVid, payloadOnly.elapsed)
    debugEcho line(biggerPayload, payloadOnly.elapsed)
    debugEcho ""
    debugEcho "  payload cache entries resident: ",
      payloadOnly.payloadLen, " / ", payloadAndVid.payloadLen, " / ",
      biggerPayload.payloadLen
    debugEcho "  vid cache entries resident:     ", payloadAndVid.vidLen

proc benchmarkOpts(): DbOptions =
  DbOptions.init(
    maxOpenFiles = 128,
    writeBufferSize = 8 * 1024 * 1024,
    rowCacheSize = 0,
    blockCacheSize = 64 * 1024 * 1024,
    rdbVtxCacheSize = 2 * 1024 * 1024,
    rdbKeyCacheSize = 4 * 1024 * 1024,
    rdbBranchCacheSize = 2 * 1024 * 1024,
    maxSnapshots = 2,
  )

proc openBaseDb(basePath: string, opts: DbOptions, wipe: bool): RocksDbInstanceRef =
  let cache =
    if opts.blockCacheSize > 0:
      cacheCreateLRU(opts.blockCacheSize, autoClose = true)
    else:
      nil
  RocksDbInstanceRef
    .open(basePath, opts.toDbOpts(), @[($VtxCF, opts.toCfOpts(cache, true))], wipe)
    .expect("open benchmark RocksDB")

proc runRdbConfig(
    basePath: string;
    opts: DbOptions;
    name: string;
    accPath: Hash32;
    slots: openArray[Hash32];
    readOrder: openArray[int];
    payloadSize, vidSize: int;
): Stats =
  # A fresh instance over the same on-disk database, so each configuration also
  # starts with a cold rdb vertex cache.
  let db = rocksDbBackend(opts, openBaseDb(basePath, opts, wipe = false))
  db.initInstance(
    accLeavesLruSize = 1024,
    stoLeavesLruSize = payloadSize,
    stoLeafVidsLruSize = vidSize,
    parallelStateRootComputation = false,
  ).expect("init instance")

  let tx = db.baseTxFrame()
  for slot in slots:
    doAssert tx.fetchSlot(accPath, slot).isOk()

  let
    hits0 = db.stoVidHits.load(moRelaxed)
    stale0 = db.stoVidStale.load(moRelaxed)
    misses0 = db.stoVidMisses.load(moRelaxed)

  var checksum = 0'u64
  let started = epochTime()
  for index in readOrder:
    checksum += tx.fetchSlot(accPath, slots[index]).expect("bench").truncate(uint64)
  let elapsed = epochTime() - started

  doAssert checksum != 0

  result = Stats(
    name: name,
    elapsed: elapsed,
    hits: db.stoVidHits.load(moRelaxed) - hits0,
    stale: db.stoVidStale.load(moRelaxed) - stale0,
    misses: db.stoVidMisses.load(moRelaxed) - misses0,
    payloadLen: db.stoLeaves.len,
    vidLen: db.stoLeafVids.len,
  )
  db.close()

suite "Aristo storage leaf vid cache benchmark (RocksDB)":
  test "cold slot reads against a real backend":
    let
      opts = benchmarkOpts()
      tmp = mkdtemp()
      basePath = tmp / "aristo"
    defer:
      removeDir(tmp)

    let accPath = makePath(0xACC0'u64)
    var slots = newSeq[Hash32](slotCount)
    for i in 0 ..< slotCount:
      slots[i] = makePath(uint64(i) + 1)

    block seed:
      let db = rocksDbBackend(opts, openBaseDb(basePath, opts, wipe = true))
      db.initInstance(parallelStateRootComputation = false).expect("init instance")
      let wtx = db.txFrameBegin(db.baseTxFrame())
      doAssert wtx.mergeAccount(
        accPath, AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH)).isOk()
      for i in 0 ..< slotCount:
        doAssert wtx.mergeSlot(accPath, slots[i], (i + 1).u256).isOk()
      wtx.checkpoint(1, skipSnapshot = true)
      let batch = db.putBegFn().expect("working batch")
      db.persist(batch, wtx)
      doAssert db.putEndFn(batch).isOk()
      db.close()

    let readOrder = makeReadOrder()

    const
      payloadEntryBytes = 8 + sizeof(Hash32) + sizeof(CachedStoLeaf)
      vidEntryBytes = 8 + sizeof(uint64) + sizeof(VertexID)
      grownPayloadSize =
        payloadCacheSize + (vidCacheSize * vidEntryBytes) div payloadEntryBytes

    # Prime the OS page cache and RocksDB block cache so that the first timed
    # configuration is not the one paying to pull the trie off disk.
    discard runRdbConfig(basePath, opts, "priming", accPath, slots,
      readOrder[0 ..< min(readOrder.len, 20_000)], payloadCacheSize, 0)

    let
      payloadOnly = runRdbConfig(basePath, opts, "payload only", accPath, slots,
        readOrder, payloadCacheSize, 0)
      payloadAndVid = runRdbConfig(basePath, opts, "payload + vid", accPath, slots,
        readOrder, payloadCacheSize, vidCacheSize)
      biggerPayload = runRdbConfig(basePath, opts, "bigger payload", accPath, slots,
        readOrder, grownPayloadSize, 0)

    debugEcho ""
    debugEcho "Aristo storage leaf vid cache benchmark (RocksDB backend)"
    debugEcho "  slots seeded:  ", slotCount, "   reads timed: ", readCount
    debugEcho ""
    debugEcho "  " & alignLeft("config", nameWidth) & align("secs", 9) &
      align("us/read", 10) & align("speedup", 9) & align("vid hits", 11) &
      align("stale", 8) & align("vid miss", 11)
    debugEcho line(payloadOnly, payloadOnly.elapsed)
    debugEcho line(payloadAndVid, payloadOnly.elapsed)
    debugEcho line(biggerPayload, payloadOnly.elapsed)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
