# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables, math],
  eth/common/keys,
  results,
  unittest2,
  ../hive_integration/nodocker/engine/tx_sender,
  ../nimbus/db/ledger,
  ../nimbus/core/chain,
  ../nimbus/core/eip4844,
  ../nimbus/[config, transaction, constants],
  ../nimbus/core/tx_pool,
  ../nimbus/core/tx_pool/tx_desc,
  ../nimbus/core/casper,
  ../nimbus/common/common,
  ../nimbus/utils/utils,
  ../nimbus/evm/types,
  ./test_txpool/helpers,
  ./macro_assembler

const
  baseDir = [".", "tests"]
  repoDir = [".", "customgenesis"]
  genesisFile = "merge.json"

type TestEnv = object
  nonce: uint64
  chainId: ChainId
  vaultKey: PrivateKey
  conf: NimbusConf
  com: CommonRef
  chain: ForkedChainRef
  xp: TxPoolRef

const
  # signerKeyHex = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
  vaultKeyHex = "63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376"
  recipient = address"0000000000000000000000000000000000000318"
  feeRecipient = address"0000000000000000000000000000000000000212"
  contractCode = evmByteCode:
    PrevRandao # VAL
    Push1 "0x11" # KEY
    Sstore # OP
    Stop

proc privKey(keyHex: string): PrivateKey =
  let kRes = PrivateKey.fromHex(keyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  kRes.get()

func makeTx(
    t: var TestEnv, recipient: Address, amount: UInt256, payload: openArray[byte] = []
): Transaction =
  const
    gasLimit = 75000.GasInt
    gasPrice = 30.gwei

  let tx = Transaction(
    txType: TxLegacy,
    chainId: t.chainId,
    nonce: AccountNonce(t.nonce),
    gasPrice: gasPrice,
    gasLimit: gasLimit,
    to: Opt.some(recipient),
    value: amount,
    payload: @payload,
  )

  inc t.nonce
  signTransaction(tx, t.vaultKey, eip155 = true)

proc createPooledTransactionWithBlob(
    t: var TestEnv, recipient: Address, amount: UInt256
): PooledTransaction =
  # Create the transaction
  let
    tc = BlobTx(
      recipient: Opt.some(recipient),
      gasLimit: 100000.GasInt,
      gasTip: GasInt(10 ^ 9),
      gasFee: GasInt(10 ^ 9),
      blobGasFee: u256(1),
      blobCount: 1,
      blobID: 1,
    )
    params = MakeTxParams(chainId: t.chainId, key: t.vaultKey, nonce: t.nonce)

  inc t.nonce
  params.makeTx(tc)

func signTxWithNonce(t: TestEnv, tx: Transaction, nonce: AccountNonce): Transaction =
  var tx = tx
  tx.nonce = nonce
  signTransaction(tx, t.vaultKey, eip155 = true)

proc initEnv(envFork: HardFork): TestEnv =
  var conf = makeConfig(
    @["--custom-network:" & genesisFile.findFilePath(baseDir, repoDir).value]
  )

  conf.networkParams.genesis.alloc[recipient] = GenesisAccount(code: contractCode)

  if envFork >= MergeFork:
    conf.networkParams.config.mergeNetsplitBlock = Opt.some(0'u64)
    conf.networkParams.config.terminalTotalDifficulty = Opt.some(100.u256)

  if envFork >= Shanghai:
    conf.networkParams.config.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    conf.networkParams.config.cancunTime = Opt.some(0.EthTime)

  let
    com =
      CommonRef.new(newCoreDbRef DefaultDbMemory, nil, conf.networkId, conf.networkParams)
    chain = newForkedChain(com, com.genesisHeader)

  result = TestEnv(
    conf: conf,
    com: com,
    chain: chain,
    xp: TxPoolRef.new(chain),
    vaultKey: privKey(vaultKeyHex),
    chainId: conf.networkParams.config.chainId,
    nonce: 0'u64,
  )

const
  amount = 1000.u256
  slot = 0x11.u256
  prevRandao = Bytes32 EMPTY_UNCLE_HASH # it can be any valid hash

proc runTxPoolPosTest() =
  var env = initEnv(MergeFork)

  var
    tx = env.makeTx(recipient, amount)
    xp = env.xp
    com = env.com
    chain = env.chain
    body: BlockBody
    blk: EthBlock

  suite "Test TxPool with PoS block":
    test "TxPool add":
      xp.add(PooledTransaction(tx: tx))

    test "TxPool jobCommit":
      check xp.nItems.total == 1

    test "TxPool ethBlock":
      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = EthTime.now()

      let r = xp.assembleBlock()
      if r.isErr:
        debugEcho r.error
        check false
        return

      blk = r.get.blk
      body = BlockBody(transactions: blk.txs, uncles: blk.uncles)
      check blk.txs.len == 1

    test "PoS persistBlocks":
      let rr = chain.importBlock(EthBlock.init(blk.header, body))
      check rr.isOk()

    test "validate TxPool prevRandao setter":
      var sdb = LedgerRef.init(com.db)
      let val = sdb.getStorage(recipient, slot)
      let randao = Bytes32(val.toBytesBE)
      check randao == prevRandao

    test "feeRecipient rewarded":
      check blk.header.coinbase == feeRecipient
      var sdb = LedgerRef.init(com.db)
      let bal = sdb.getBalance(feeRecipient)
      check not bal.isZero

proc runTxPoolBlobhashTest() =
  var env = initEnv(Cancun)

  var
    tx1 = env.createPooledTransactionWithBlob(recipient, amount)
    tx2 = env.createPooledTransactionWithBlob(recipient, amount)
    xp = env.xp
    com = env.com
    chain = env.chain
    body: BlockBody
    blk: EthBlock

  suite "Test TxPool with blobhash block":
    test "TxPool jobCommit":
      xp.add(tx1)
      xp.add(tx2)
      check xp.nItems.total == 2

    test "TxPool ethBlock":
      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = EthTime.now()

      let r = xp.assembleBlock()
      if r.isErr:
        debugEcho r.error
        check false
        return

      let bundle = r.get
      blk = bundle.blk
      body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles,
        withdrawals: Opt.some(newSeq[Withdrawal]()),
      )
      check blk.txs.len == 2

      let
        gasUsed1 = xp.vmState.receipts[0].cumulativeGasUsed
        gasUsed2 = xp.vmState.receipts[1].cumulativeGasUsed - gasUsed1
        totalBlobGasUsed = tx1.tx.getTotalBlobGas + tx2.tx.getTotalBlobGas
        blockValue =
          gasUsed1.u256 * tx1.tx.effectiveGasTip(blk.header.baseFeePerGas).u256 +
          gasUsed2.u256 * tx2.tx.effectiveGasTip(blk.header.baseFeePerGas).u256

      check blockValue == bundle.blockValue
      check totalBlobGasUsed == blk.header.blobGasUsed.get()

    test "Blobhash persistBlocks":
      let rr = chain.importBlock(EthBlock.init(blk.header, body))
      check rr.isOk()

    test "validate TxPool prevRandao setter":
      var sdb = LedgerRef.init(com.db)
      let val = sdb.getStorage(recipient, slot)
      let randao = Bytes32(val.toBytesBE)
      check randao == prevRandao

    test "feeRecipient rewarded":
      check blk.header.coinbase == feeRecipient
      var sdb = LedgerRef.init(com.db)
      let bal = sdb.getBalance(feeRecipient)
      check not bal.isZero

    test "add tx with nonce too low":
      let
        tx3 = env.makeTx(recipient, amount)
        tx4 = env.signTxWithNonce(tx3, AccountNonce(env.nonce - 2))
        xp = env.xp

      check xp.smartHead(blk.header)
      xp.add(PooledTransaction(tx: tx4))

      check inPoolAndOk(xp, rlpHash(tx4)) == false

proc runTxHeadDelta(noisy = true) =
  ## see github.com/status-im/nimbus-eth1/issues/1031

  suite "TxPool: Synthesising blocks (covers issue #1031)":
    test "Packing and adding multiple blocks to chain":
      var
        env = initEnv(MergeFork)
        xp = env.xp
        com = env.com
        chain = env.chain
        head = chain.latestHeader
        timestamp = head.timestamp

      const
        txPerblock = 20
        numBlocks = 10

      # setTraceLevel()

      block:
        for n in 0 ..< numBlocks:
          for tn in 0 ..< txPerblock:
            let tx = env.makeTx(recipient, amount)
            xp.add(PooledTransaction(tx: tx))

          noisy.say "***",
            "txDB",
            &" n={n}",
            # pending/staged/packed : total/disposed
            &" stats={xp.nItems.pp}"

          timestamp = timestamp + 1
          com.pos.prevRandao = prevRandao
          com.pos.timestamp = timestamp
          com.pos.feeRecipient = feeRecipient

          let r = xp.assembleBlock()
          if r.isErr:
            debugEcho r.error
            check false
            return

          let blk = r.get.blk
          let body = BlockBody(transactions: blk.txs, uncles: blk.uncles)

          # Commit to block chain
          check chain.importBlock(EthBlock.init(blk.header, body)).isOk

          # Synchronise TxPool against new chain head, register txs differences.
          # In this particular case, these differences will simply flush the
          # packer bucket.
          check xp.smartHead(blk.header)

          # Move TxPool chain head to new chain head and apply delta jobs
          check xp.nItems.staged == 0
          check xp.nItems.packed == 0

          setErrorLevel() # in case we set trace level

      check com.syncCurrent == 10.BlockNumber
      head = chain.headerByNumber(com.syncCurrent).expect("block header exists")
      let
        sdb = LedgerRef.init(com.db)
        expected = u256(txPerblock * numBlocks) * amount
        balance = sdb.getBalance(recipient)
      check balance == expected

proc runGetBlockBodyTest() =
  var
    env = initEnv(Cancun)
    blockTime = EthTime.now()
    parentHeader: Header
    currentHeader: Header

  suite "Test get parent transactions after persistBlock":
    test "TxPool create first block":
      let
        tx1 = env.makeTx(recipient, 1.u256)
        tx2 = env.makeTx(recipient, 2.u256)

      env.xp.add(PooledTransaction(tx: tx1))
      env.xp.add(PooledTransaction(tx: tx2))

      env.com.pos.prevRandao = prevRandao
      env.com.pos.feeRecipient = feeRecipient
      env.com.pos.timestamp = blockTime

      let r = env.xp.assembleBlock()
      if r.isErr:
        check false
        return

      let blk = r.get.blk
      check env.chain.importBlock(blk).isOk
      parentHeader = blk.header
      check env.xp.smartHead(parentHeader)
      check blk.transactions.len == 2

    test "TxPool create second block":
      let
        tx1 = env.makeTx(recipient, 3.u256)
        tx2 = env.makeTx(recipient, 4.u256)
        tx3 = env.makeTx(recipient, 5.u256)

      env.xp.add(PooledTransaction(tx: tx1))
      env.xp.add(PooledTransaction(tx: tx2))
      env.xp.add(PooledTransaction(tx: tx3))

      env.com.pos.prevRandao = prevRandao
      env.com.pos.feeRecipient = feeRecipient
      env.com.pos.timestamp = blockTime + 1

      let r = env.xp.assembleBlock()
      if r.isErr:
        check false
        return

      let blk = r.get.blk
      check env.chain.importBlock(blk).isOk
      currentHeader = blk.header
      check env.xp.smartHead(currentHeader)
      check blk.transactions.len == 3
      let currHash = currentHeader.blockHash
      check env.chain.forkChoice(currHash, currHash).isOk

proc txPool2Main*() =
  const noisy = defined(debug)

  loadKzgTrustedSetup().expect("Failed to load KZG trusted setup")

  setErrorLevel() # mute logger

  runTxPoolPosTest()
  runTxPoolBlobhashTest()
  noisy.runTxHeadDelta
  runGetBlockBodyTest()

when isMainModule:
  txPool2Main()

# End
