# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  pkg/chronos,
  pkg/unittest2,
  results,
  eth/[common, rlp],
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/utils/utils,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/db/kvt,
  ../execution_chain/db/kvt/[kvt_desc, kvt_utils],
  ../execution_chain/db/storage_types,
  ../execution_chain/block_access_list/bal_utils,
  ../execution_chain/bal_pruner,
  ../execution_chain/pruner/db_utils

const
  genesisFile = "tests/customgenesis/cancun123.json"

type
  TestEnv = object
    config: ExecutionClientConf
    params: NetworkParams

proc setupEnv(): TestEnv =
  let
    config = makeConfig(@["--network:" & genesisFile])
    params = config.computeNetworkParams()

  TestEnv(config: config, params: params)

proc newCom(env: TestEnv): CommonRef =
  CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    env.params
  )

# Helper: store a key-value pair directly in the KVT backend
proc putBe(kvt: KvtDbRef, key, value: openArray[byte]) =
  let batch = kvt.putBegFn().expect("putBegFn")
  kvt.putKvpFn(batch, key, value)
  kvt.putEndFn(batch).expect("putEndFn")

# Helper: check if a key exists in the KVT backend
proc hasBe(kvt: KvtDbRef, key: openArray[byte]): bool =
  kvt.getBe(key).isOk

suite "Block access list pruner tests":
  const balBytes = @[1'u8, 2, 3]

  var env = setupEnv()

  # Builds a canonical header chain on top of genesis where each block from
  # `firstBalBlock` onwards is an Amsterdam block sitting in its own epoch and
  # holding a block access list. Returns the block hashes indexed by number.
  proc buildChain(
      com: CommonRef, numBlocks: int, firstBalBlock: int
  ): seq[Hash32] =
    let
      kvt = com.db.kvt
      txFrame = com.db.baseTxFrame()

    var hashes = @[com.genesisHeader.computeBlockHash]
    for i in 1 .. numBlocks:
      let hasBal = i >= firstBalBlock
      var header = Header(
        number: BlockNumber(i),
        parentHash: hashes[i - 1],
        difficulty: 0.u256,
      )
      if hasBal:
        header.baseFeePerGas = Opt.some(0.u256)
        header.withdrawalsRoot = Opt.some(EMPTY_ROOT_HASH)
        header.blobGasUsed = Opt.some(0'u64)
        header.excessBlobGas = Opt.some(0'u64)
        header.parentBeaconBlockRoot = Opt.some(default(Hash32))
        header.requestsHash = Opt.some(default(Hash32))
        header.blockAccessListHash = Opt.some(
          hash32"6666666666666666666666666666666666666666666666666666666666666666")
        header.slotNumber = Opt.some(uint64(i) * SLOTS_PER_EPOCH)

      let blkHash = header.computeBlockHash
      txFrame.persistHeader(blkHash, header).expect("persistHeader")
      hashes.add blkHash

      if hasBal:
        kvt.putBe(blockHashToBlockAccessListKey(blkHash).toOpenArray, balBytes)

    hashes

  proc hasBal(kvt: KvtDbRef, blkHash: Hash32): bool =
    kvt.hasBe(blockHashToBlockAccessListKey(blkHash).toOpenArray)

  # The head slot such that all blocks up to and including `lastPrunedBlock`
  # fall outside of the retention period
  func headSlotFor(lastPrunedBlock: int): uint64 =
    (BAL_RETENTION_EPOCHS + uint64(lastPrunedBlock)) * SLOTS_PER_EPOCH

  test "block access lists outside the retention period are deleted":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 1)
      pruner = BalPrunerRef.init(com)
      pruned = waitFor pruner.prune(BlockNumber(10), headSlotFor(5))

    check pruned == 5

    for i in 1 .. 5:
      check not kvt.hasBal(hashes[i])
    for i in 6 .. 10:
      check kvt.hasBal(hashes[i])

    check kvt.getBalTailBe() == BlockNumber(6)

  test "block access lists within the retention period are retained":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 1)
      pruner = BalPrunerRef.init(com)
      pruned = waitFor pruner.prune(BlockNumber(10), headSlotFor(0))

    check pruned == 0

    for i in 1 .. 10:
      check kvt.hasBal(hashes[i])

    check kvt.getBalTailBe() == BlockNumber(1)

  test "pruning starts at the first block holding a block access list":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 5)
      pruner = BalPrunerRef.init(com)
      pruned = waitFor pruner.prune(BlockNumber(10), headSlotFor(7))

    check pruned == 3

    for i in 5 .. 7:
      check not kvt.hasBal(hashes[i])
    for i in 8 .. 10:
      check kvt.hasBal(hashes[i])

    check kvt.getBalTailBe() == BlockNumber(8)

  test "the first block search skips over unreadable headers":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 5)
      txFrame = com.db.baseTxFrame()

    # Only blocks 5 and above are stored, as on a snap synced node
    for i in 1 .. 4:
      txFrame.del(blockNumberToHashKey(BlockNumber(i)).toOpenArray).expect("del")

    let
      pruner = BalPrunerRef.init(com)
      pruned = waitFor pruner.prune(BlockNumber(10), headSlotFor(7))

    check pruned == 3

    for i in 5 .. 7:
      check not kvt.hasBal(hashes[i])
    for i in 8 .. 10:
      check kvt.hasBal(hashes[i])

    check kvt.getBalTailBe() == BlockNumber(8)

  test "pruning stops at an unreadable block and skips it on the next cycle":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 1)

    com.db.baseTxFrame().del(
      blockNumberToHashKey(BlockNumber(3)).toOpenArray).expect("del")

    let pruner = BalPrunerRef.init(com)

    # The cycle stops at the unreadable block, keeping the progress made so far
    check (waitFor pruner.prune(BlockNumber(10), headSlotFor(5))) == 2
    check kvt.getBalTailBe() == BlockNumber(3)

    # The next cycle skips over it
    check (waitFor pruner.prune(BlockNumber(10), headSlotFor(5))) == 0
    check kvt.getBalTailBe() == BlockNumber(4)

    # And the remaining blocks outside of the retention period are pruned
    check (waitFor pruner.prune(BlockNumber(10), headSlotFor(5))) == 2

    for i in [1, 2, 4, 5]:
      check not kvt.hasBal(hashes[i])
    check kvt.hasBal(hashes[3])
    for i in 6 .. 10:
      check kvt.hasBal(hashes[i])

    check kvt.getBalTailBe() == BlockNumber(6)

  test "the cutoff search treats unreadable blocks as within retention":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 1)

    kvt.setBalTailBe(BlockNumber(1))
    com.db.baseTxFrame().del(
      blockNumberToHashKey(BlockNumber(5)).toOpenArray).expect("del")

    let
      pruner = BalPrunerRef.init(com)
      pruned = waitFor pruner.prune(BlockNumber(10), headSlotFor(5))

    check pruned == 4

    for i in 1 .. 4:
      check not kvt.hasBal(hashes[i])
    check kvt.hasBal(hashes[5])
    for i in 6 .. 10:
      check kvt.hasBal(hashes[i])

    check kvt.getBalTailBe() == BlockNumber(5)

    check (waitFor pruner.prune(BlockNumber(10), headSlotFor(5))) == 0

    check kvt.hasBal(hashes[5])
    check kvt.getBalTailBe() == BlockNumber(6)

  test "the tail is not advanced when the head trails the tail":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 1)
      pruner = BalPrunerRef.init(com)

    kvt.setBalTailBe(BlockNumber(8))

    # Block 8 is outside of the retention period but sits ahead of the head, so
    # there is nothing to prune and the tail must stay where it is
    for _ in 1 .. 3:
      check (waitFor pruner.prune(BlockNumber(5), headSlotFor(9))) == 0
      check kvt.getBalTailBe() == BlockNumber(8)

    for i in 1 .. 10:
      check kvt.hasBal(hashes[i])

  test "pruning resumes from the stored tail":
    let
      com = env.newCom()
      kvt = com.db.kvt
      hashes = com.buildChain(numBlocks = 10, firstBalBlock = 1)

    check (waitFor BalPrunerRef.init(com, batchSize = 2).prune(
      BlockNumber(10), headSlotFor(4))) == 4

    let pruner = BalPrunerRef.init(com)
    check kvt.getBalTailBe() == BlockNumber(5)

    # Only the blocks which newly fell outside of the retention period are
    # visited in the second run
    check (waitFor pruner.prune(BlockNumber(10), headSlotFor(6))) == 2

    for i in 1 .. 6:
      check not kvt.hasBal(hashes[i])
    for i in 7 .. 10:
      check kvt.hasBal(hashes[i])

    check kvt.getBalTailBe() == BlockNumber(7)

  test "pruning is a no-op before Amsterdam":
    let
      com = env.newCom()
      pruner = BalPrunerRef.init(com, loopDelay = chronos.milliseconds(50))

    pruner.start()
    waitFor sleepAsync(chronos.milliseconds(100))
    waitFor pruner.stop()

    check com.db.kvt.getBalTailBe() == BlockNumber(0)
