# nimbus-eth1
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  eth/common/hashes,
  results,
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/core/chain/forked_chain,
  ../execution_chain/core/tx_pool,
  ../execution_chain/core/pooled_txs,
  ../execution_chain/transaction,
  ../execution_chain/db/aristo/[aristo_desc, aristo_tx_blobify],
  ../execution_chain/db/kvt/[kvt_desc, kvt_tx_blobify],
  ../execution_chain/db/[storage_types, tx_frame_db, ledger],
  ../execution_chain/db/core_db/memory_only,
  ../hive_integration/tx_sender,
  unittest2

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
    sender = TxSender.new(config.networkParams, 5)
    com    = CommonRef.new(
              newCoreDbRef DefaultDbMemory,
              config.networkId,
              config.networkParams)
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

  test "kvt_tx_blobify: empty frame round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    let blob = blobifyKvtTxFrame(frame.kTx)
    let rc = deblobifyKvtTxFrame(blob)
    check rc.isOk
    check rc.value.len == 0
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

  test "kvt_tx_blobify: wrong version returns error":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    var blob = blobifyKvtTxFrame(frame.kTx)
    blob[0] = 0xFF'u8
    let rc = deblobifyKvtTxFrame(blob)
    check rc.isErr
    check rc.error == DataInvalid
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

  test "kvt_tx_blobify: single entry round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    frame.kTx.sTab[@[1'u8, 2, 3]] = @[0xDE'u8, 0xAD, 0xBE, 0xEF]
    let blob = blobifyKvtTxFrame(frame.kTx)
    let rc = deblobifyKvtTxFrame(blob)
    check rc.isOk
    check rc.value.len == 1
    check rc.value[@[1'u8, 2, 3]] == @[0xDE'u8, 0xAD, 0xBE, 0xEF]
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

    let bundle1Rc = xp.assembleBlock()
    check bundle1Rc.isOk
    let blk1 = bundle1Rc.get.blk
    check blk1.transactions.len == 3
    check (waitFor chain.importBlock(blk1)).isOk
    xp.removeNewBlockTxs(blk1)

    let
      blk1Hash = blk1.header.computeBlockHash
      txFrame1 = chain.txFrame(blk1Hash)

    # --- Capture pre-state from the populated txFrame ---
    let
      preSTabLen          = txFrame1.aTx.sTab.len
      preKMapLen          = txFrame1.aTx.kMap.len
      preAccLeavesLen     = txFrame1.aTx.accLeaves.len
      preStoLeavesLen     = txFrame1.aTx.stoLeaves.len
      preVTop             = txFrame1.aTx.vTop
      preBlockNumber      = txFrame1.aTx.blockNumber
      preKvtLen           = txFrame1.kTx.sTab.len
      preRecipientBalance = LedgerRef.init(txFrame1).getBalance(recipient)
      preSenderBalance    = LedgerRef.init(txFrame1).getBalance(acc.address)
    check preSTabLen > 0
    check preAccLeavesLen >= 2  # at least sender + recipient
    check preKvtLen > 0
    check preRecipientBalance == 300.u256  # 3 txs * 100 wei
    check txFrame1.getBlockHeader(blk1Hash).isOk

    # --- Round-trip both halves through blobify/deblobify ---
    let aBlob = blobifyTxFrame(txFrame1.aTx)
    let kBlob = blobifyKvtTxFrame(txFrame1.kTx)
    check aBlob.len > 1
    check kBlob.len > 1

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

    let kRc = deblobifyKvtTxFrame(kBlob)
    check kRc.isOk
    restored.kTx.sTab = kRc.value

    # --- Round-trip equality assertions ---
    check restored.aTx.sTab.len == preSTabLen
    check restored.aTx.kMap.len == preKMapLen
    check restored.aTx.accLeaves.len == preAccLeavesLen
    check restored.aTx.stoLeaves.len == preStoLeavesLen
    check restored.aTx.vTop == preVTop
    check restored.aTx.blockNumber == preBlockNumber
    check restored.kTx.sTab.len == preKvtLen

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
    let bundle2Rc = xp.assembleBlock()
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
    check txFrame2.aTx.accLeaves.len > 0

    restored.dispose()

when isMainModule:
  discard
