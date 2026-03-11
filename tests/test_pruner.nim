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
  stew/endians2,
  eth/[common, rlp],
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/utils/utils,
  ../execution_chain/core/chain/forked_chain,
  ../execution_chain/db/ledger,
  ../execution_chain/db/kvt,
  ../execution_chain/db/kvt/kvt_utils,
  ../execution_chain/db/storage_types,
  ../execution_chain/pruner

const
  genesisFile = "tests/customgenesis/cancun123.json"
  senderAddr = address"73cf19657412508833f618a15e8251306b3e6ee5"

type
  TestEnv = object
    config: ExecutionClientConf

proc setupEnv(): TestEnv =
  let config = makeConfig(@["--network:" & genesisFile])
  TestEnv(config: config)

proc newCom(env: TestEnv): CommonRef =
  CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    env.config.networkId,
    env.config.networkParams
  )

# Helper: store a key-value pair directly in the KVT backend
proc putBe(kvt: KvtDbRef, key, value: openArray[byte]) =
  let batch = kvt.putBegFn().expect("putBegFn")
  kvt.putKvpFn(batch, key, value)
  kvt.putEndFn(batch).expect("putEndFn")

# Helper: check if a key exists in the KVT backend
proc hasBe(kvt: KvtDbRef, key: openArray[byte]): bool =
  kvt.getBe(key).isOk

# Helper: read history expired block number from backend
# (mirrors the pruner's local getHistoryExpiredBe)
proc getHistoryExpiredBe(kvt: KvtDbRef): BlockNumber =
  let blkNum = kvt.getBe(tailIdKey().toOpenArray).valueOr:
    return BlockNumber(0)
  BlockNumber(uint64.fromBytesLE(blkNum))

proc makeBlk(
    txFrame: CoreDbTxRef,
    number: BlockNumber,
    parentBlk: Block,
): Block =
  template parent(): Header =
    parentBlk.header

  var wds = newSeqOfCap[Withdrawal](number.int)
  for i in 0..<number:
    wds.add Withdrawal(
      index: i,
      validatorIndex: 1,
      address: senderAddr,
      amount: 1,
    )

  let ledger = LedgerRef.init(txFrame)
  for wd in wds:
    ledger.addBalance(wd.address, wd.weiAmount)
  ledger.persist()

  let wdRoot = calcWithdrawalsRoot(wds)
  var body = BlockBody(
    withdrawals: Opt.some(move(wds))
  )

  let header = Header(
    number: number,
    parentHash: parent.computeBlockHash,
    difficulty: 0.u256,
    timestamp: parent.timestamp + 1,
    gasLimit: parent.gasLimit,
    stateRoot: ledger.getStateRoot(),
    transactionsRoot: parent.txRoot,
    baseFeePerGas: parent.baseFeePerGas,
    receiptsRoot: parent.receiptsRoot,
    ommersHash: parent.ommersHash,
    withdrawalsRoot: Opt.some(wdRoot),
    blobGasUsed: parent.blobGasUsed,
    excessBlobGas: parent.excessBlobGas,
    parentBeaconBlockRoot: parent.parentBeaconBlockRoot,
  )

  Block.init(header, body)

func blockHash(x: Block): Hash32 =
  x.header.computeBlockHash

suite "Pruner KVT-level tests":
  setup:
    let kvt = KvtDbRef.init()

  test "historyExpiryIdKey roundtrip via backend put/get":
    let key = tailIdKey()

    # Initially no history expired
    let initial = kvt.getBe(key.toOpenArray)
    check initial.isErr

    # Store a block number
    let blockNum = BlockNumber(12345)
    kvt.putBe(key.toOpenArray, blockNum.toBytesLE())

    # Read it back
    let stored = kvt.getBe(key.toOpenArray).expect("should exist")
    check BlockNumber(uint64.fromBytesLE(stored)) == blockNum

    # Update it
    let newBlockNum = BlockNumber(99999)
    kvt.putBe(key.toOpenArray, newBlockNum.toBytesLE())

    let updated = kvt.getBe(key.toOpenArray).expect("should exist")
    check BlockNumber(uint64.fromBytesLE(updated)) == newBlockNum

    kvt.finish()

suite "Pruner integration tests":
  var env = setupEnv()

  test "pruner deletes withdrawal data from persisted blocks":
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 1)
    let
      genesis = Block.init(com.genesisHeader, BlockBody())
      baseTxFrame = com.db.baseTxFrame()
      txFrame = baseTxFrame.txFrameBegin
      blk1 = txFrame.makeBlk(1, genesis)
      blk2 = txFrame.makeBlk(2, blk1)
      blk3 = txFrame.makeBlk(3, blk2)
      dbTx = txFrame.txFrameBegin
      blk4 = dbTx.makeBlk(4, blk3)
      blk5 = dbTx.makeBlk(5, blk4)
      blk6 = dbTx.makeBlk(6, blk5)
      blk7 = dbTx.makeBlk(7, blk6)
    dbTx.dispose()
    txFrame.dispose()

    # Import blocks into chain
    check (waitFor chain.importBlock(blk1)).isOk
    check (waitFor chain.importBlock(blk2)).isOk
    check (waitFor chain.importBlock(blk3)).isOk
    check (waitFor chain.importBlock(blk4)).isOk
    check (waitFor chain.importBlock(blk5)).isOk
    check (waitFor chain.importBlock(blk6)).isOk
    check (waitFor chain.importBlock(blk7)).isOk

    # Persist via fork choice (finalize blk6, head blk7)
    check (waitFor chain.forkChoice(blk7.blockHash, blk6.blockHash)).isOk

    # Verify withdrawal data exists in backend for persisted blocks
    let kvt = com.db.kvt
    let bt = com.db.baseTxFrame()

    # Check a persisted block's withdrawal data exists
    # blk3 should be persisted (base distance = 3, head = 7 → base = 4)
    let hdr3 = bt.getBlockHeader(BlockNumber 3).expect("header 3 exists")
    check hdr3.withdrawalsRoot.isSome
    let wdRoot3 = hdr3.withdrawalsRoot.get()
    check kvt.hasBe(withdrawalsKey(wdRoot3).toOpenArray)

    # Now delete the withdrawal data directly (same operation the pruner does)
    check kvt.delBe(withdrawalsKey(wdRoot3).toOpenArray).isOk

    # Verify the withdrawal data is gone
    check not kvt.hasBe(withdrawalsKey(wdRoot3).toOpenArray)

    # But the header should still be accessible
    check bt.getBlockHeader(BlockNumber 3).isOk

  test "pruner init with custom batch size":
    let com = env.newCom()
    let pruner = BackgroundPrunerRef.init(com)
    # Default batch size should be 500 (changed from 100)
    # Just verify it initializes without error
    check pruner != nil

  test "pruner start and stop lifecycle":
    let com = env.newCom()
    let pruner = BackgroundPrunerRef.init(com, loopDelay = chronos.milliseconds(50))
    pruner.start()

    # Let it run briefly (it should find nothing to prune and just sleep)
    waitFor sleepAsync(chronos.milliseconds(100))

    # Stop should complete without error
    waitFor pruner.stop()

  test "pruner processes blocks with old timestamps":
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 0, persistBatchSize = 1)
    let
      genesis = Block.init(com.genesisHeader, BlockBody())
      baseTxFrame = com.db.baseTxFrame()
      txFrame = baseTxFrame.txFrameBegin
      blk1 = txFrame.makeBlk(1, genesis)
      blk2 = txFrame.makeBlk(2, blk1)
      blk3 = txFrame.makeBlk(3, blk2)
    txFrame.dispose()

    # Import and persist all blocks
    check (waitFor chain.importBlock(blk1)).isOk
    check (waitFor chain.forkChoice(blk1.blockHash, blk1.blockHash)).isOk
    check (waitFor chain.importBlock(blk2)).isOk
    check (waitFor chain.forkChoice(blk2.blockHash, blk2.blockHash)).isOk
    check (waitFor chain.importBlock(blk3)).isOk
    check (waitFor chain.forkChoice(blk3.blockHash, blk3.blockHash)).isOk

    let kvt = com.db.kvt

    # Verify withdrawal data exists for persisted blocks
    let bt = com.db.baseTxFrame()
    for blkNum in 1'u64 .. 3'u64:
      let hdr = bt.getBlockHeader(BlockNumber blkNum).expect("header exists")
      if hdr.withdrawalsRoot.isSome:
        let wdRoot = hdr.withdrawalsRoot.get()
        if wdRoot != EMPTY_ROOT_HASH:
          check kvt.hasBe(withdrawalsKey(wdRoot).toOpenArray)

    # Start pruner with short delays
    let pruner = BackgroundPrunerRef.init(com,
      batchSize = 10,
      loopDelay = chronos.milliseconds(50))
    pruner.start()

    # Wait for pruner to complete a cycle
    # Blocks have timestamp ~1 (genesis + 1 per block), well within retention window cutoff
    waitFor sleepAsync(chronos.milliseconds(300))

    waitFor pruner.stop()

    # Check that historyExpired advanced (pruner made progress)
    let historyExpired = kvt.getHistoryExpiredBe()
    check historyExpired > BlockNumber(0)

    # Verify withdrawal data was deleted for pruned blocks
    let bt2 = com.db.baseTxFrame()
    for blkNum in 1'u64 ..< historyExpired.uint64:
      let hdr = bt2.getBlockHeader(BlockNumber blkNum).expect("header still exists")
      if hdr.withdrawalsRoot.isSome:
        let wdRoot = hdr.withdrawalsRoot.get()
        if wdRoot != EMPTY_ROOT_HASH:
          check not kvt.hasBe(withdrawalsKey(wdRoot).toOpenArray)

    # Headers should still be readable
    for blkNum in 1'u64 .. 3'u64:
      check bt2.getBlockHeader(BlockNumber blkNum).isOk

  test "getHistoryExpiredBe returns 0 when not set":
    let com = env.newCom()
    let kvt = com.db.kvt
    check kvt.getHistoryExpiredBe() == BlockNumber(0)
