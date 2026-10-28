# nimbus-eth1
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[strutils, tables],
  pkg/chronos,
  stew/endians2,
  eth/common/hashes,
  results,
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/core/chain/forked_chain,
  ../execution_chain/core/chain/forked_chain/chain_serialize,
  ../execution_chain/core/tx_pool,
  ../execution_chain/core/pooled_txs,
  ../execution_chain/transaction,
  ../execution_chain/db/aristo/[aristo_desc, aristo_get, aristo_tx_blobify],
  ../execution_chain/db/kvt/[kvt_desc],
  ../execution_chain/db/[storage_types, tx_frame_db, ledger],
  ../execution_chain/db/core_db/memory_only,
  ./transaction/tx_sender,
  unittest2

proc buildTxFrameBlob(aBlob: openArray[byte]): seq[byte] =
  result = newSeqOfCap[byte](4 + aBlob.len)
  result.add aBlob.len.uint32.toBytesBE
  for b in aBlob: result.add b

const
  genesisFile  = "tests/customgenesis/cancun123.json"
  feeRecipient = address"0000000000000000000000000000000000000212"
  recipient    = address"00000000000000000000000000000000000000aa"

type
  TestEnv = object
    config: ExecutionClientConf
    com   : CommonRef
    chain : ForkedChainRef
    xp    : TxPoolRef
    sender: TxSender

proc setupEnv(): TestEnv =
  let
    config = makeConfig(@["--network:" & genesisFile])
    params = config.computeNetworkParams()
    sender = TxSender.new(params, 5)
    com    = CommonRef.new(
              newCoreDbRef DefaultDbMemory,
              params)
    chain  = ForkedChainRef.init(com)
  TestEnv(
    config: config,
    com:    com,
    chain:  chain,
    xp:     TxPoolRef.new(chain),
    sender: sender)

suite "TxFrame blobify round-trip":

  test "storage_types: txFrameKey has correct discriminator":
    let h = Hash32.fromHex("0x" & "ab".repeat(32))
    let k = txFrameKey(h)
    check k.dataEndPos == 32
    check k.data[0] == byte(16)        # DBKeyKind.txFrame = 16
    check k.data[1 .. 32] == h.data

  test "aristo_tx_blobify: empty frame round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    let blob = blobifyTxFrame(frame.aTx)
    let rc = deblobifyTxFrame(blob)
    check rc.isOk
    let d = rc.value
    check d.vTop == frame.aTx.vTop
    check d.blockNumber == frame.aTx.blockNumber
    check d.sTab.len == 0
    check d.accLeaves.len == 0
    check d.stoLeaves.len == 0
    frame.dispose()

  test "aristo_tx_blobify: wrong version returns error":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    var blob = blobifyTxFrame(frame.aTx)
    blob[0] = 0xFF'u8
    let rc = deblobifyTxFrame(blob)
    check rc.isErr
    check rc.error == DeblobTxFrameVersion
    frame.dispose()

  test "aristo_tx_blobify: blockNumber round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    frame.aTx.blockNumber = Opt.some(42'u64)
    let blob = blobifyTxFrame(frame.aTx)
    let rc = deblobifyTxFrame(blob)
    check rc.isOk
    check rc.value.blockNumber == Opt.some(42'u64)
    frame.dispose()

  test "forked-chain importBlock txFrame round-trip with transactions":
    let env = setupEnv()
    let
      com   = env.com
      chain = env.chain
      xp    = env.xp
      mx    = env.sender
      acc   = mx.getAccount(0)

    xp.feeRecipient = feeRecipient
    xp.prevRandao   = default(Bytes32)
    xp.timestamp    = EthTime.now()

    # --- Block 1: assemble + import three real transactions ---
    for i in 0..<3:
      let ptx = mx.makeTx(
        BaseTx(
          gasLimit : 75000,
          recipient: Opt.some(recipient),
          amount   : 100.u256),
        acc, i.AccountNonce)
      check xp.addTx(ptx).isOk

    let bundle1Rc = xp.assembleBlock(xp.chain.latestHash)
    check bundle1Rc.isOk
    let blk1 = bundle1Rc.get.blk
    check blk1.transactions.len == 3
    check (waitFor chain.importBlock(blk1)).isOk
    xp.removeNewBlockTxs(blk1)

    let
      blk1Hash = blk1.header.computeBlockHash
      txFrame1 = chain.txFrame(blk1Hash)

    # --- Capture pre-state from the populated txFrame. After import it keeps
    # only its snapshot, which holds the changes since base: blk1's ---
    var preKMapLen = 0
    for item in txFrame1.aTx.snapshot.vtx.values:
      if item[1] != VOID_HASH_KEY:
        inc preKMapLen
    let
      preSTabLen          = txFrame1.aTx.snapshot.vtx.len
      preAccLeavesLen     = txFrame1.aTx.snapshot.acc.len
      preStoLeavesLen     = txFrame1.aTx.snapshot.sto.len
      preVTop             = txFrame1.aTx.vTop
      preBlockNumber      = txFrame1.aTx.blockNumber
      preRecipientBalance = LedgerRef.init(txFrame1).getBalance(recipient)
      preSenderBalance    = LedgerRef.init(txFrame1).getBalance(acc.address)
    check preSTabLen > 0
    check preAccLeavesLen >= 2  # at least sender + recipient
    check preRecipientBalance == 300.u256  # 3 txs * 100 wei
    check txFrame1.getBlockHeader(blk1Hash).isOk

    # --- Round-trip the Aristo delta blobified at import ---
    let stored = com.db.baseTxFrame().get(txFrameKey(blk1Hash).toOpenArray)
    check stored.isOk
    let aBlob = stored.get[4 .. ^1]
    check aBlob.len > 1

    let restored = com.db.baseTxFrame().txFrameBegin()

    let aRc = deblobifyTxFrame(aBlob)
    check aRc.isOk
    let aData = aRc.value
    restored.aTx.sTab        = aData.sTab
    restored.aTx.kMap        = aData.kMap
    restored.aTx.accLeaves   = aData.accLeaves
    restored.aTx.stoLeaves   = aData.stoLeaves
    restored.aTx.vTop        = aData.vTop
    restored.aTx.blockNumber = aData.blockNumber

    # --- Round-trip equality assertions ---
    check restored.aTx.sTab.len == preSTabLen
    check restored.aTx.kMap.len == preKMapLen
    check restored.aTx.accLeaves.len == preAccLeavesLen
    check restored.aTx.stoLeaves.len == preStoLeavesLen
    check restored.aTx.vTop == preVTop
    check restored.aTx.blockNumber == preBlockNumber

    # --- Functional reads on restored frame ---
    check LedgerRef.init(restored).getBalance(recipient) == preRecipientBalance
    check LedgerRef.init(restored).getBalance(acc.address) == preSenderBalance
    check restored.getBlockHeader(blk1Hash).isOk
    # Each of blk1's transactions should be retrievable from the restored frame
    for idx in 0 ..< blk1.transactions.len:
      let txRc = restored.getTransactionByIndex(blk1.header.txRoot, idx.uint16)
      check txRc.isOk

    # --- Block 2: two more transactions on top of the chain (which sits on
    # the same state we just round-tripped) ---
    for i in 3..<5:
      let ptx = mx.makeTx(
        BaseTx(
          gasLimit : 75000,
          recipient: Opt.some(recipient),
          amount   : 100.u256),
        acc, i.AccountNonce)
      check xp.addTx(ptx).isOk

    xp.timestamp = xp.timestamp + 1
    let bundle2Rc = xp.assembleBlock(xp.chain.latestHash)
    check bundle2Rc.isOk
    let blk2 = bundle2Rc.get.blk
    check blk2.transactions.len == 2
    check (waitFor chain.importBlock(blk2)).isOk

    let
      blk2Hash = blk2.header.computeBlockHash
      txFrame2 = chain.txFrame(blk2Hash)
    check LedgerRef.init(txFrame2).getBalance(recipient) ==
      preRecipientBalance + 200.u256  # blk2: 2 txs * 100 wei
    check txFrame2.getBlockHeader(blk2Hash).isOk
    check txFrame2.aTx.snapshot.acc.len > 0

    restored.dispose()

  test "forked-chain serialize/deserialize uses txFrame blobs":
    let env = setupEnv()
    let
      com   = env.com
      chain = env.chain
      xp    = env.xp
      mx    = env.sender
      acc   = mx.getAccount(0)

    xp.feeRecipient = feeRecipient
    xp.prevRandao   = default(Bytes32)
    xp.timestamp    = EthTime.now()

    # --- blk1: 3 transactions ---
    for i in 0..<3:
      let ptx = mx.makeTx(
        BaseTx(
          gasLimit : 75000,
          recipient: Opt.some(recipient),
          amount   : 100.u256),
        acc, i.AccountNonce)
      check xp.addTx(ptx).isOk

    let bundle1 = xp.assembleBlock(xp.chain.latestHash).get
    let blk1 = bundle1.blk
    check blk1.transactions.len == 3
    check (waitFor chain.importBlock(blk1)).isOk
    xp.removeNewBlockTxs(blk1)

    # --- blk2: 2 more transactions ---
    for i in 3..<5:
      let ptx = mx.makeTx(
        BaseTx(
          gasLimit : 75000,
          recipient: Opt.some(recipient),
          amount   : 100.u256),
        acc, i.AccountNonce)
      check xp.addTx(ptx).isOk

    xp.timestamp = xp.timestamp + 1
    let bundle2 = xp.assembleBlock(xp.chain.latestHash).get
    let blk2 = bundle2.blk
    check blk2.transactions.len == 2
    check (waitFor chain.importBlock(blk2)).isOk
    xp.removeNewBlockTxs(blk2)

    let
      blk1Hash = blk1.header.computeBlockHash
      blk2Hash = blk2.header.computeBlockHash

    # --- Capture pre-state from the chain's per-block txFrames ---
    let
      txFrame1 = chain.txFrame(blk1Hash)
      txFrame2 = chain.txFrame(blk2Hash)
    let
      preBlk1STabLen      = txFrame1.aTx.snapshot.vtx.len
      preBlk1AccLeavesLen = txFrame1.aTx.snapshot.acc.len
      preBlk1VTop         = txFrame1.aTx.vTop
      preBlk1Recipient    = LedgerRef.init(txFrame1).getBalance(recipient)
      preBlk1Sender       = LedgerRef.init(txFrame1).getBalance(acc.address)
      preBlk2Recipient    = LedgerRef.init(txFrame2).getBalance(recipient)
      preChainBlocks      = chain.hashToBlock.len
      preChainHeads       = chain.heads.len
    check preBlk1Recipient == 300.u256
    check preBlk2Recipient == 500.u256
    check preBlk1STabLen > 0

    # --- Serialize + persist ---
    let serializeFrame = chain.baseTxFrame
    check chain.serialize(serializeFrame).isOk
    serializeFrame.checkpoint(chain.base.header.number, skipSnapshot = true)
    com.db.persist(serializeFrame)

    # --- New ForkedChainRef on the same com; deserialize from disk ---
    var fc = ForkedChainRef.init(com)
    let dRc = fc.deserialize()
    check dRc.isOk

    # --- High-level shape matches ---
    check fc.hashToBlock.len == preChainBlocks
    check fc.heads.len       == preChainHeads

    # Loading must leave the snapshot intact for another restart or a retry.
    check fc.baseTxFrame.hasKey(txFrameKey(blk1Hash).toOpenArray)
    check fc.baseTxFrame.hasKey(txFrameKey(blk2Hash).toOpenArray)
    let restartedAgain = ForkedChainRef.init(com)
    check restartedAgain.deserialize().isOk
    check LedgerRef.init(restartedAgain.txFrame(blk2Hash)).getBalance(recipient) ==
      preBlk2Recipient

    # --- Per-block field equality proves no-replay path ---
    # If replay() were still being used, freshly-built deltas would yield
    # different sTab/vTop than the originals. Byte-for-byte equality here
    # is only achievable by restoring the persisted blob.
    let restoredBlk1 = fc.txFrame(blk1Hash)
    check restoredBlk1.aTx.snapshot.vtx.len == preBlk1STabLen
    check restoredBlk1.aTx.snapshot.acc.len == preBlk1AccLeavesLen
    check restoredBlk1.aTx.vTop          == preBlk1VTop

    # --- Functional reads on the restored chain ---
    check LedgerRef.init(restoredBlk1).getBalance(recipient) == preBlk1Recipient
    check LedgerRef.init(restoredBlk1).getBalance(acc.address) == preBlk1Sender
    check restoredBlk1.getBlockHeader(blk1Hash).isOk

    let restoredBlk2 = fc.txFrame(blk2Hash)
    check LedgerRef.init(restoredBlk2).getBalance(recipient) == preBlk2Recipient
    check restoredBlk2.getBlockHeader(blk2Hash).isOk

    # --- Continuation: import blk3 with two more txs onto the
    # deserialized chain. Proves the restored frames remain writable. ---
    let xp2 = TxPoolRef.new(fc)
    xp2.feeRecipient = feeRecipient
    xp2.prevRandao   = default(Bytes32)
    xp2.timestamp    = xp.timestamp + 1
    for i in 5..<7:
      let ptx = mx.makeTx(
        BaseTx(
          gasLimit : 75000,
          recipient: Opt.some(recipient),
          amount   : 100.u256),
        acc, i.AccountNonce)
      check xp2.addTx(ptx).isOk

    let bundle3 = xp2.assembleBlock(xp2.chain.latestHash).get
    let blk3 = bundle3.blk
    check blk3.transactions.len == 2
    check (waitFor fc.importBlock(blk3)).isOk

    let blk3Hash = blk3.header.computeBlockHash
    let restoredBlk3 = fc.txFrame(blk3Hash)
    check LedgerRef.init(restoredBlk3).getBalance(recipient) ==
      preBlk2Recipient + 200.u256

  test "finalization preserves shared transactions and deletes exclusive payloads":
    let env = setupEnv()
    let
      chain = env.chain
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(0)
      parent = chain.latestHash
    xp.feeRecipient = feeRecipient
    xp.timestamp = EthTime.now()
    let tx = mx.makeTx(BaseTx(gasLimit: 75000, recipient: Opt.some(recipient),
                             amount: 100.u256), acc, 0.AccountNonce)
    check xp.addTx(tx).isOk
    let canonical = xp.assembleBlock(parent).get.blk
    xp.removeNewBlockTxs(canonical)
    var shared = canonical
    shared.header.extraData = @[1'u8]

    let xp2 = TxPoolRef.new(chain)
    xp2.feeRecipient = feeRecipient
    xp2.timestamp = xp.timestamp
    let other = mx.makeTx(BaseTx(gasLimit: 75000, recipient: Opt.some(recipient),
                                amount: 200.u256), acc, 0.AccountNonce)
    check xp2.addTx(other).isOk
    let exclusive = xp2.assembleBlock(parent).get.blk
    doAssert exclusive.transactions.len == 1
    check (waitFor chain.importBlock(canonical)).isOk
    check (waitFor chain.importBlock(shared)).isOk
    check (waitFor chain.importBlock(exclusive)).isOk
    let hash = canonical.header.computeBlockHash
    check (chain.forkChoice(hash, hash)).isOk

    let db = chain.baseTxFrame
    check db.getEthBlock(hash).get.transactions == canonical.transactions
    check db.getReceipts(canonical.header.receiptsRoot).get.len == 1
    check db.getTransactionByIndex(exclusive.header.txRoot, 0).isErr
    check not db.hasKey(transactionHashToBlockKey(
      exclusive.transactions[0].computeRlpHash).toOpenArray)
    check chain.txDetailsByTxHash(canonical.transactions[0].computeRlpHash).
      get == (hash, 0'u64)
    check not db.hasKey(genericHashKey(shared.header.computeBlockHash).toOpenArray)
    check not db.hasKey(genericHashKey(exclusive.header.computeBlockHash).toOpenArray)

  test "finalization keeps a transaction on a surviving descendant":
    let env = setupEnv()
    let
      chain = env.chain
      xp = env.xp
      mx = env.sender
      genesis = chain.latestHash
    xp.feeRecipient = feeRecipient
    xp.timestamp = EthTime.now()
    let canonical = xp.assembleBlock(genesis).get.blk
    let tx = mx.makeTx(BaseTx(gasLimit: 75000, recipient: Opt.some(recipient),
                             amount: 100.u256), mx.getAccount(0), 0.AccountNonce)
    check xp.addTx(tx).isOk
    let dead = xp.assembleBlock(genesis).get.blk
    check (waitFor chain.importBlock(canonical)).isOk
    xp.timestamp = xp.timestamp + 1
    let canonicalHash = canonical.header.computeBlockHash
    let survivor = xp.assembleBlock(canonicalHash).get.blk
    doAssert survivor.transactions.len == 1
    check (waitFor chain.importBlock(survivor)).isOk
    # Import the dead fork last so both indexes initially point at it.
    check (waitFor chain.importBlock(dead)).isOk
    check (chain.forkChoice(canonicalHash, canonicalHash)).isOk

    let hash = survivor.transactions[0].computeRlpHash
    # Above base, the tx lookup is in memory only
    check chain.baseTxFrame.getTransactionKey(hash).get.blockNumber == 0
    check chain.txDetailsByTxHash(hash).get ==
      (survivor.header.computeBlockHash, 0'u64)
    check chain.baseTxFrame.getEthBlock(survivor.header.computeBlockHash).
      get.transactions == survivor.transactions
    check chain.baseTxFrame.getBlockHeader(dead.header.computeBlockHash).isErr

  test "loadTxFrameAsChild: missing key returns Err":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let h = Hash32.fromHex("0x" & "21".repeat(32))
    let base = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base, base, h)
    check rc.isErr

  test "loadTxFrameAsChild: blob shorter than 4 bytes returns DataInvalid":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let h = Hash32.fromHex("0x" & "22".repeat(32))
    check coreDb.baseTxFrame.put(
      txFrameKey(h).toOpenArray, @[1'u8, 2, 3]).isOk
    let base = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base, base, h)
    check rc.isErr
    check "blob too short" in rc.error.ctx

  test "loadTxFrameAsChild: aristo region truncated returns Err":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let h = Hash32.fromHex("0x" & "23".repeat(32))
    var blob = newSeq[byte]()
    blob.add uint32(1000).toBytesBE
    blob.add uint32(0).toBytesBE
    check coreDb.baseTxFrame.put(txFrameKey(h).toOpenArray, blob).isOk
    let base = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base, base, h)
    check rc.isErr
    check "invalid aristo region length" in rc.error.ctx

  test "loadTxFrameAsChild: trailing bytes return Err":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    let aBlob = blobifyTxFrame(frame.aTx)
    frame.dispose()

    let h = Hash32.fromHex("0x" & "24".repeat(32))
    var blob = newSeqOfCap[byte](4 + aBlob.len)
    blob.add aBlob.len.uint32.toBytesBE
    for b in aBlob: blob.add b
    blob.add uint32(1000).toBytesBE
    check coreDb.baseTxFrame.put(txFrameKey(h).toOpenArray, blob).isOk
    let base = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base, base, h)
    check rc.isErr
    check "invalid aristo region length" in rc.error.ctx

  test "loadTxFrameAsChild: corrupted aristo blob returns Err":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    var aBlob = blobifyTxFrame(frame.aTx)
    aBlob[0] = 0xFF'u8
    frame.dispose()

    let h = Hash32.fromHex("0x" & "25".repeat(32))
    let blob = buildTxFrameBlob(aBlob)
    check coreDb.baseTxFrame.put(txFrameKey(h).toOpenArray, blob).isOk
    let base = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base, base, h)
    check rc.isErr
    check "aristo deblobify" in rc.error.ctx

  test "loadTxFrameAsChild: empty aristo region returns Err":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let h = Hash32.fromHex("0x" & "26".repeat(32))
    check coreDb.baseTxFrame.put(txFrameKey(h).toOpenArray, 0'u32.toBytesBE).isOk
    let base = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base, base, h)
    check rc.isErr
    check "invalid aristo region length" in rc.error.ctx

  test "loadTxFrameAsChild: deleted hash returns not found":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let src    = coreDb.txFrameBegin()
    let h      = Hash32.fromHex("0x" & "32".repeat(32))
    check coreDb.baseTxFrame.storeTxFrame(src, h).isOk
    src.dispose()

    let base = coreDb.baseTxFrame
    let pre  = loadTxFrameAsChild(base, base, h)
    check pre.isOk
    pre.value.dispose()

    check coreDb.baseTxFrame.deleteTxFrame(h).isOk
    let probe = coreDb.baseTxFrame.get(txFrameKey(h).toOpenArray)
    check probe.isErr and probe.error.error == KvtNotFound

    let base2 = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base2, base2, h)
    check rc.isErr
    check rc.error.error == KvtNotFound

  test "loadTxFrameAsChild: stored frame round-trips":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let src = coreDb.txFrameBegin()
    src.aTx.blockNumber = Opt.some(99'u64)

    let h = Hash32.fromHex("0x" & "27".repeat(32))
    check coreDb.baseTxFrame.storeTxFrame(src, h).isOk

    let base = coreDb.baseTxFrame
    let rc = loadTxFrameAsChild(base, base, h)
    check rc.isOk
    let loaded = rc.value
    check loaded.aTx.blockNumber == Opt.some(99'u64)

    loaded.dispose()
    src.dispose()

  test "foldTxFrame: newer frame wins, folded newest first":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let base = coreDb.baseTxFrame
    template rv(n: int): RootedVertexID = (VertexID(1), VertexID(n))
    template br(n: int): VertexRef = BranchRef.init(VertexID(n), 0x0003'u16)
    let
      older = coreDb.txFrameBegin()
      newer = coreDb.txFrameBegin()
      k1 = HashKey.fromBytes(Hash32.fromHex("0x" & "11".repeat(32)).data).expect("key")
      k4 = HashKey.fromBytes(Hash32.fromHex("0x" & "44".repeat(32)).data).expect("key")
      p1 = Hash32.fromHex("0x" & "a1".repeat(32))
      p2 = Hash32.fromHex("0x" & "a2".repeat(32))
      hOld = Hash32.fromHex("0x" & "41".repeat(32))
      hNew = Hash32.fromHex("0x" & "42".repeat(32))

    older.aTx.vTop = VertexID(10)
    older.aTx.blockNumber = Opt.some(1'u64)
    older.aTx.sTab[rv(2)] = br(20)
    older.aTx.kMap[rv(2)] = k1
    older.aTx.sTab[rv(3)] = br(30)
    older.aTx.sTab[rv(4)] = br(40)
    older.aTx.kMap[rv(4)] = k4
    older.aTx.stoLeaves[p1] = StoLeafRef.init(default(NibblesBuf), 1.u256)
    older.aTx.stoLeaves[p2] = StoLeafRef.init(default(NibblesBuf), 2.u256)

    # Rewritten without a key yet, deleted, and a deleted leaf
    newer.aTx.vTop = VertexID(11)
    newer.aTx.blockNumber = Opt.some(2'u64)
    newer.aTx.sTab[rv(2)] = br(21)
    newer.aTx.sTab[rv(3)] = nil
    newer.aTx.stoLeaves[p1] = nil

    check base.storeTxFrame(older, hOld).isOk
    check base.storeTxFrame(newer, hNew).isOk
    older.dispose()
    newer.dispose()

    var data: TxFrameSnapshot
    check base.foldTxFrame(data, hNew, 2).get == Opt.some(2'u64)
    check base.foldTxFrame(data, hOld, 1).get == Opt.some(1'u64)

    # Each entry is stamped with the level of the frame that wrote it
    template vtx(n: int): VtxSnapshot = data.snapshot.vtx[rv(n)]
    check data.vTop == VertexID(11)
    check data.blockNumber == Opt.some(2'u64)
    check BranchRef(vtx(2)[0]).startVid == VertexID(21)
    check vtx(2)[1] == VOID_HASH_KEY
    check vtx(2)[2] == 2
    check vtx(3)[0].isNil
    check vtx(3)[2] == 2
    check BranchRef(vtx(4)[0]).startVid == VertexID(40)
    check vtx(4)[1] == k4
    check vtx(4)[2] == 1
    check data.snapshot.sto[p1][0].isNil
    check data.snapshot.sto[p1][1] == 2
    check data.snapshot.sto[p2][0].stoData == 2.u256
    check data.snapshot.sto[p2][1] == 1

  test "snapshotFrame: state the base frame holds in memory stays readable":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let base = coreDb.baseTxFrame
    template rv(n: int): RootedVertexID = (VertexID(1), VertexID(n))
    template br(n: int): VertexRef = BranchRef.init(VertexID(n), 0x0003'u16)
    let
      p1 = Hash32.fromHex("0x" & "a1".repeat(32))
      p2 = Hash32.fromHex("0x" & "a2".repeat(32))
      h = Hash32.fromHex("0x" & "45".repeat(32))

    # Written to the base frame but not persisted, like a test genesis
    base.aTx.sTab[rv(2)] = br(20)
    base.aTx.sTab[rv(4)] = br(40)
    base.aTx.stoLeaves[p1] = StoLeafRef.init(default(NibblesBuf), 1.u256)

    let blk = base.txFrameBegin()
    blk.aTx.sTab[rv(3)] = br(30)
    blk.aTx.sTab[rv(4)] = br(41)
    blk.aTx.stoLeaves[p2] = StoLeafRef.init(default(NibblesBuf), 2.u256)
    blk.checkpoint(1, skipSnapshot = false)
    check base.storeTxFrame(blk, h).isOk
    blk.detach()

    var data: TxFrameSnapshot
    check base.foldTxFrame(data, h, blk.aTx.level).get == Opt.some(1'u64)
    let frame = base.snapshotFrame(data, blk.aTx.level)

    # The block's own entries win over the base frame's
    template startVid(n: int): VertexID =
      let vtx = frame.aTx.getVtx(rv(n))
      if vtx.isNil: VertexID(0) else: BranchRef(vtx).startVid
    check startVid(2) == VertexID(20)
    check startVid(3) == VertexID(30)
    check startVid(4) == VertexID(41)
    check p1 in frame.aTx.snapshot.sto
    check p2 in frame.aTx.snapshot.sto

    frame.dispose()

  test "foldTxFrame: missing blob returns Err":
    let coreDb = newCoreDbRef(AristoDbMemory)
    var data: TxFrameSnapshot
    let rc = coreDb.baseTxFrame.foldTxFrame(data, Hash32.fromHex("0x" & "43".repeat(32)), 1)
    check rc.isErr
    check rc.error.error == KvtNotFound

when isMainModule:
  discard
