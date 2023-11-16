# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  std/[algorithm, math, sequtils, strformat, times],
  stew/byteutils,
  rocksdb,
  unittest2,
  ../../nimbus/core/chain,
  ../../nimbus/db/core_db,
  ../../nimbus/db/core_db/persistent,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[hexary_desc, rocky_bulk_load],
  ../../nimbus/utils/prettify,
  ../replay/[pp, undump_blocks]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to*(b: openArray[byte]; T: type ByteArray32): T =
  ## Convert to other representation (or exception)
  if b.len == 32:
    (addr result[0]).copyMem(unsafeAddr b[0], 32)
  else:
    doAssert b.len == 32

proc to*(b: openArray[byte]; T: type ByteArray33): T =
  ## Convert to other representation (or exception)
  if b.len == 33:
    (addr result[0]).copyMem(unsafeAddr b[0], 33)
  else:
    doAssert b.len == 33

proc to*(b: ByteArray32|ByteArray33; T: type Blob): T =
  b.toSeq

proc to*(b: openArray[byte]; T: type NodeTag): T =
  ## Convert from serialised equivalent
  UInt256.fromBytesBE(b).T

proc to*(w: (byte, NodeTag); T: type Blob): T =
  let (b,t) = w
  @[b] & toSeq(t.UInt256.toBytesBE)

proc to*(t: NodeTag; T: type Blob): T =
  toSeq(t.UInt256.toBytesBE)

# ----------------

proc thisRecord(r: rocksdb_iterator_t): (Blob,Blob) =
  var kLen, vLen:  csize_t
  let
    kData = r.rocksdb_iter_key(addr kLen)
    vData = r.rocksdb_iter_value(addr vLen)
  if not kData.isNil and not vData.isNil:
    let
      key = string.fromBytes(toOpenArrayByte(kData,0,int(kLen)-1))
      value = string.fromBytes(toOpenArrayByte(vData,0,int(vLen)-1))
    return (key.mapIt(it.byte),value.mapIt(it.byte))

proc meanStdDev(sum, sqSum: float; length: int): (float,float) =
  if 0 < length:
    result[0] = sum / length.float
    result[1] = sqrt(sqSum / length.float - result[0] * result[0])

# ------------------------------------------------------------------------------
# Public functions, pretty printing
# ------------------------------------------------------------------------------

proc pp*(d: Duration): string =
  if 40 < d.inSeconds:
    d.ppMins
  elif 200 < d.inMilliseconds:
    d.ppSecs
  elif 200 < d.inMicroseconds:
    d.ppMs
  else:
    d.ppUs

proc ppKvPc*(w: openArray[(string,int)]): string =
  w.mapIt(&"{it[0]}={it[1]}%").join(", ")

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# Public test function: setup
# ------------------------------------------------------------------------------

proc test_dbTimingUndumpBlocks*(
    noisy: bool;
    filePath: string;
    com: CommonRef;
    numBlocks: int;
    loadNoise = false;
      ) =
  ## Store persistent blocks from dump into chain DB
  let chain = com.newChain

  for w in filePath.undumpBlocks:
    let (fromBlock, toBlock) = (w[0][0].blockNumber, w[0][^1].blockNumber)
    if fromBlock == 0.u256:
      doAssert w[0][0] == com.db.getBlockHeader(0.u256)
      continue
    # Message if [fromBlock,toBlock] contains a multiple of 700
    if fromBlock + (toBlock mod 900) <= toBlock:
      loadNoise.say "***", &"processing ...[#{fromBlock},#{toBlock}]..."
    check chain.persistBlocks(w[0], w[1]) == ValidationResult.OK
    if numBlocks.toBlockNumber <= w[0][^1].blockNumber:
      break

proc test_dbTimingRockySetup*(
    noisy: bool;
    t32: var Table[ByteArray32,Blob],
    t33: var Table[ByteArray33,Blob],
    cdb: CoreDbRef;
     ) =
  ## Extract key-value records into memory tables via rocksdb iterator
  let
    rdb = cdb.backend.toRocksStoreRef
    rop = rdb.store.readOptions
    rit = rdb.store.db.rocksdb_create_iterator(rop)
  check not rit.isNil

  var
    v32Sum, v32SqSum: float   # statistics
    v33Sum, v33SqSum: float

  t32.clear
  t33.clear

  rit.rocksdb_iter_seek_to_first()
  while rit.rocksdb_iter_valid() != 0:
    let (key,val) = rit.thisRecord()
    rit.rocksdb_iter_next()
    if key.len == 32:
      t32[key.to(ByteArray32)] = val
      v32Sum += val.len.float
      v32SqSum += val.len.float * val.len.float
      check key.to(ByteArray32).to(Blob) == key
    elif key.len == 33:
      t33[key.to(ByteArray33)] = val
      v33Sum += val.len.float
      v33SqSum += val.len.float * val.len.float
      check key.to(ByteArray33).to(Blob) == key
    else:
      noisy.say "***", "ignoring key=", key.toHex

  rit.rocksdb_iter_destroy()

  var
    (mean32, stdv32) = meanStdDev(v32Sum, v32SqSum, t32.len)
    (mean33, stdv33) = meanStdDev(v33Sum, v33SqSum, t33.len)
  noisy.say "***",
    "key 32 table: ",
    &"size={t32.len} valLen={(mean32+0.5).int}({(stdv32+0.5).int})",
    ", key 33 table: ",
    &"size={t33.len} valLen={(mean33+0.5).int}({(stdv33+0.5).int})"

# ------------------------------------------------------------------------------
# Public test function: timing
# ------------------------------------------------------------------------------

proc test_dbTimingStoreDirect32*(
    noisy: bool;
    t32: Table[ByteArray32,Blob];
    cdb: CoreDbRef;
     ) =
  ## Direct db, key length 32, no transaction
  var ela: Duration
  let tdb = cdb.kvt

  if noisy: echo ""
  noisy.showElapsed("Standard db loader(keyLen 32)", ela):
    for (key,val) in t32.pairs:
      tdb.put(key, val)

  if ela.inNanoseconds != 0:
    let
      elaNs = ela.inNanoseconds.float
      perRec = ((elaNs / t32.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t32.len, ", ",
      "perRecord=", perRec.pp

proc test_dbTimingStoreDirectly32as33*(
    noisy: bool;
    t32: Table[ByteArray32,Blob],
    cdb: CoreDbRef;
     ) =
  ## Direct db, key length 32 as 33, no transaction
  var ela = initDuration()
  let tdb = cdb.kvt

  if noisy: echo ""
  noisy.showElapsed("Standard db loader(keyLen 32 as 33)", ela):
    for (key,val) in t32.pairs:
      tdb.put(@[99.byte] & key.toSeq, val)

  if ela.inNanoseconds != 0:
    let
      elaNs = ela.inNanoseconds.float
      perRec = ((elaNs / t32.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t32.len, ", ",
      "perRecord=", perRec.pp

proc test_dbTimingStoreTx32*(
    noisy: bool;
    t32: Table[ByteArray32,Blob],
    cdb: CoreDbRef;
     ) =
  ## Direct db, key length 32, transaction based
  var ela: Duration
  let tdb = cdb.kvt

  if noisy: echo ""
  noisy.showElapsed("Standard db loader(tx,keyLen 32)", ela):
    let dbTx = cdb.beginTransaction
    defer: dbTx.commit

    for (key,val) in t32.pairs:
      tdb.put(key, val)

  if ela.inNanoseconds != 0:
    let
      elaNs = ela.inNanoseconds.float
      perRec = ((elaNs / t32.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t32.len, ", ",
      "perRecord=", perRec.pp

proc test_dbTimingStoreTx32as33*(
    noisy: bool;
    t32: Table[ByteArray32,Blob],
    cdb: CoreDbRef;
     ) =
  ## Direct db, key length 32 as 33, transaction based
  var ela: Duration
  let tdb = cdb.kvt

  if noisy: echo ""
  noisy.showElapsed("Standard db loader(tx,keyLen 32 as 33)", ela):
    let dbTx = cdb.beginTransaction
    defer: dbTx.commit

    for (key,val) in t32.pairs:
      tdb.put(@[99.byte] & key.toSeq, val)

  if ela.inNanoseconds != 0:
    let
      elaNs = ela.inNanoseconds.float
      perRec = ((elaNs / t32.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t32.len, ", ",
      "perRecord=", perRec.pp

proc test_dbTimingDirect33*(
    noisy: bool;
    t33: Table[ByteArray33,Blob],
    cdb: CoreDbRef;
     ) =
  ## Direct db, key length 33, no transaction
  var ela: Duration
  let tdb = cdb.kvt

  if noisy: echo ""
  noisy.showElapsed("Standard db loader(keyLen 33)", ela):
    for (key,val) in t33.pairs:
      tdb.put(key, val)

  if ela.inNanoseconds != 0:
    let
      elaNs = ela.inNanoseconds.float
      perRec = ((elaNs / t33.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t33.len, ", ",
      "perRecord=", perRec.pp

proc test_dbTimingTx33*(
    noisy: bool;
    t33: Table[ByteArray33,Blob],
    cdb: CoreDbRef;
     ) =
  ## Direct db, key length 33, transaction based
  var ela: Duration
  let tdb = cdb.kvt

  if noisy: echo ""
  noisy.showElapsed("Standard db loader(tx,keyLen 33)", ela):
    let dbTx = cdb.beginTransaction
    defer: dbTx.commit

    for (key,val) in t33.pairs:
      tdb.put(key, val)

  if ela.inNanoseconds != 0:
    let
      elaNs = ela.inNanoseconds.float
      perRec = ((elaNs / t33.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t33.len, ", ",
      "perRecord=", perRec.pp

proc test_dbTimingRocky32*(
    noisy: bool;
    t32: Table[ByteArray32,Blob],
    cdb: CoreDbRef;
    fullNoise = false;
     ) =
  ## Rocksdb, key length 32
  var
    ela: array[4,Duration]
    size: int64
  let
    rdb = cdb.backend.toRocksStoreRef

  # Note that 32 and 33 size keys cannot be usefully merged into the same SST
  # file. The keys must be added in a sorted mode. So playing safe, key sizes
  # should be of equal length.

  if noisy: echo ""
  noisy.showElapsed("Rocky bulk loader(keyLen 32)", ela[0]):
    let bulker = RockyBulkLoadRef.init(rdb)
    defer: bulker.destroy()
    check bulker.begin("rocky-bulk-cache")

    var
      keyList = newSeq[NodeTag](t32.len)

    fullNoise.showElapsed("Rocky bulk loader/32, sorter", ela[1]):
      var inx = 0
      for key in t32.keys:
        keyList[inx] = key.to(NodeTag)
        inx.inc
      keyList.sort(cmp)

    fullNoise.showElapsed("Rocky bulk loader/32, append", ela[2]):
      for n,nodeTag in keyList:
        let key = nodeTag.to(Blob)
        check bulker.add(key, t32[key.to(ByteArray32)])

    fullNoise.showElapsed("Rocky bulk loader/32, slurp", ela[3]):
      let rc = bulker.finish()
      if rc.isOk:
         size = rc.value
      else:
        check bulker.lastError == "" # force printing error

  fullNoise.say "***", " ela[]=", $ela.toSeq.mapIt(it.pp)
  if ela[0].inNanoseconds != 0:
    let
      elaNs = ela.toSeq.mapIt(it.inNanoseconds.float)
      elaPc = elaNs.mapIt(((it / elaNs[0]) * 100 + 0.5).int)
      perRec = ((elaNs[0] / t32.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t32.len, ", ",
      "perRecord=", perRec.pp, ", ",
      "sstSize=", size.uint64.toSI, ", ",
      "perRecord=", ((size.float / t32.len.float) + 0.5).int, ", ",
     ["Total","Sorter","Append","Ingest"].zip(elaPc).ppKvPc

proc test_dbTimingRocky32as33*(
    noisy: bool;
    t32: Table[ByteArray32,Blob],
    cdb: CoreDbRef;
    fullNoise = false;
     ) =
  ## Rocksdb, key length 32 as 33
  var
    ela: array[4,Duration]
    size: int64
  let
    rdb = cdb.backend.toRocksStoreRef

  # Note that 32 and 33 size keys cannot be usefiully merged into the same SST
  # file. The keys must be added in a sorted mode. So playing safe, key sizes
  # should be of equal length.

  if noisy: echo ""
  noisy.showElapsed("Rocky bulk loader(keyLen 32 as 33)", ela[0]):
    let bulker = RockyBulkLoadRef.init(rdb)
    defer: bulker.destroy()
    check bulker.begin("rocky-bulk-cache")

    var
      keyList = newSeq[NodeTag](t32.len)

    fullNoise.showElapsed("Rocky bulk loader/32 as 33, sorter", ela[1]):
      var inx = 0
      for key in t32.keys:
        keyList[inx] = key.to(NodeTag)
        inx.inc
      keyList.sort(cmp)

    fullNoise.showElapsed("Rocky bulk loader/32 as 33, append", ela[2]):
      for n,nodeTag in keyList:
        let key = nodeTag.to(Blob)
        check bulker.add(@[99.byte] & key, t32[key.to(ByteArray32)])

    fullNoise.showElapsed("Rocky bulk loader/32 as 33, slurp", ela[3]):
      let rc = bulker.finish()
      if rc.isOk:
         size = rc.value
      else:
        check bulker.lastError == "" # force printing error

  fullNoise.say "***", " ela[]=", $ela.toSeq.mapIt(it.pp)
  if ela[0].inNanoseconds != 0:
    let
      elaNs = ela.toSeq.mapIt(it.inNanoseconds.float)
      elaPc = elaNs.mapIt(((it / elaNs[0]) * 100 + 0.5).int)
      perRec = ((elaNs[0] / t32.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t32.len, ", ",
      "perRecord=", perRec.pp, ", ",
      "sstSize=", size.uint64.toSI, ", ",
      "perRecord=", ((size.float / t32.len.float) + 0.5).int, ", ",
     ["Total","Sorter","Append","Ingest"].zip(elaPc).ppKvPc

proc test_dbTimingRocky33*(
    noisy: bool;
    t33: Table[ByteArray33,Blob],
    cdb: CoreDbRef;
    fullNoise = false;
     ) =
  ##  Rocksdb, key length 33
  var
    ela: array[4,Duration]
    size: int64
  let rdb = cdb.backend.toRocksStoreRef

  # Note that 32 and 33 size keys cannot be usefiully merged into the same SST
  # file. The keys must be added in a sorted mode. So playing safe, key sizes
  # should be of equal length.

  if noisy: echo ""
  noisy.showElapsed("Rocky bulk loader(keyLen 33)", ela[0]):
    let bulker = RockyBulkLoadRef.init(rdb)
    defer: bulker.destroy()
    check bulker.begin("rocky-bulk-cache")

    var
      kKeys: seq[byte] # need to cacscade
      kTab: Table[byte,seq[NodeTag]]

    fullNoise.showElapsed("Rocky bulk loader/33, sorter", ela[1]):
      for key in t33.keys:
        if kTab.hasKey(key[0]):
          kTab[key[0]].add key.toOpenArray(1,32).to(NodeTag)
        else:
          kTab[key[0]] = @[key.toOpenArray(1,32).to(NodeTag)]

      kKeys = toSeq(kTab.keys).sorted
      for w in kKeys:
        kTab[w].sort(cmp)

    fullNoise.showElapsed("Rocky bulk loader/33, append", ela[2]):
      for w in kKeys:
        fullNoise.say "***", " prefix=", w, " entries=", kTab[w].len
        for n,nodeTag in kTab[w]:
          let key = (w,nodeTag).to(Blob)
          check bulker.add(key, t33[key.to(ByteArray33)])

    fullNoise.showElapsed("Rocky bulk loader/33, slurp", ela[3]):
      let rc = bulker.finish()
      if rc.isOk:
         size = rc.value
      else:
        check bulker.lastError == "" # force printing error

  fullNoise.say "***", " ela[]=", $ela.toSeq.mapIt(it.pp)
  if ela[0].inNanoseconds != 0:
    let
      elaNs = ela.toSeq.mapIt(it.inNanoseconds.float)
      elaPc = elaNs.mapIt(((it / elaNs[0]) * 100 + 0.5).int)
      perRec = ((elaNs[0] / t33.len.float) + 0.5).int.initDuration
    noisy.say "***",
      "nRecords=", t33.len, ", ",
      "perRecord=", perRec.pp, ", ",
      "sstSize=", size.uint64.toSI, ", ",
      "perRecord=", ((size.float / t33.len.float) + 0.5).int, ", ",
      ["Total","Cascaded-Sorter","Append","Ingest"].zip(elaPc).ppKvPc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
