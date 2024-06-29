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
  std/tables,
  eth/[keys],
  stew/byteutils, results, unittest2,
  ../nimbus/db/ledger,
  ../nimbus/core/chain,
  ../nimbus/[config, transaction, constants],
  ../nimbus/core/tx_pool,
  ../nimbus/core/casper,
  ../nimbus/common/common,
  ../nimbus/utils/utils,
  ./test_txpool/helpers,
  ./macro_assembler

const
  baseDir = [".", "tests"]
  repoDir = [".", "customgenesis"]
  genesisFile = "merge.json"

type
  TestEnv = object
    nonce   : uint64
    chainId : ChainId
    vaultKey: PrivateKey
    conf    : NimbusConf
    com     : CommonRef
    chain   : ChainRef
    xp      : TxPoolRef

const
  signerKeyHex = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
  vaultKeyHex = "63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376"
  recipient = hexToByteArray[20]("0000000000000000000000000000000000000318")
  feeRecipient = hexToByteArray[20]("0000000000000000000000000000000000000212")
  contractCode = evmByteCode:
    PrevRandao    # VAL
    Push1 "0x11"  # KEY
    Sstore        # OP
    Stop

proc privKey(keyHex: string): PrivateKey =
  let kRes = PrivateKey.fromHex(keyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  kRes.get()

func makeTx(
    t: var TestEnv, recipient: EthAddress, amount: UInt256,
    payload: openArray[byte] = []): Transaction =
  const
    gasLimit = 75000.GasInt
    gasPrice = 30.gwei

  let tx = Transaction(
    txType  : TxLegacy,
    chainId : t.chainId,
    nonce   : AccountNonce(t.nonce),
    gasPrice: gasPrice,
    gasLimit: gasLimit,
    to      : Opt.some(recipient),
    value   : amount,
    payload : @payload
  )

  inc t.nonce
  signTransaction(tx, t.vaultKey, t.chainId, eip155 = true)

func signTxWithNonce(
    t: TestEnv, tx: Transaction, nonce: AccountNonce): Transaction =
  var tx = tx
  tx.nonce = nonce
  signTransaction(tx, t.vaultKey, t.chainId, eip155 = true)

proc initEnv(envFork: HardFork): TestEnv =
  var
    conf = makeConfig(@[
      "--custom-network:" & genesisFile.findFilePath(baseDir,repoDir).value
    ])

  conf.networkParams.genesis.alloc[recipient] = GenesisAccount(
    code: contractCode
  )

  if envFork >= MergeFork:
    conf.networkParams.config.terminalTotalDifficulty = Opt.some(100.u256)

  if envFork >= Shanghai:
    conf.networkParams.config.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    conf.networkParams.config.cancunTime = Opt.some(0.EthTime)

  let
    com = CommonRef.new(
      newCoreDbRef DefaultDbMemory,
      conf.networkId,
      conf.networkParams
    )
    chain = newChain(com)

  com.initializeEmptyDb()

  result = TestEnv(
    conf: conf,
    com: com,
    chain: chain,
    xp: TxPoolRef.new(com),
    vaultKey: privKey(vaultKeyHex),
    chainId: conf.networkParams.config.chainId,
    nonce: 0'u64
  )

const
  amount = 1000.u256
  slot = 0x11.u256
  prevRandao = EMPTY_UNCLE_HASH # it can be any valid hash

proc runTxPoolPosTest() =
  var
    env = initEnv(MergeFork)

  var
    tx = env.makeTx(recipient, amount)
    xp = env.xp
    com = env.com
    chain = env.chain
    body: BlockBody
    blk: EthBlock

  suite "Test TxPool with PoS block":
    test "TxPool addLocal":
      let res = xp.addLocal(PooledTransaction(tx: tx), force = true)
      check res.isOk
      if res.isErr:
        debugEcho res.error
        return

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
      check com.isBlockAfterTtd(blk.header)

      body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles
      )
      check blk.txs.len == 1

    test "PoS persistBlocks":
      let rr = chain.persistBlocks([EthBlock.init(blk.header, body)])
      check rr.isOk()

    test "validate TxPool prevRandao setter":
      var sdb = LedgerRef.init(com.db, blk.header.stateRoot)
      let val = sdb.getStorage(recipient, slot)
      let randao = Hash256(data: val.toBytesBE)
      check randao == prevRandao

    test "feeRecipient rewarded":
      check blk.header.coinbase == feeRecipient
      var sdb = LedgerRef.init(com.db, blk.header.stateRoot)
      let bal = sdb.getBalance(feeRecipient)
      check not bal.isZero

proc runTxPoolBlobhashTest() =
  var
    env = initEnv(Cancun)

  var
    tx1 = env.makeTx(recipient, amount)
    tx2 = env.makeTx(recipient, amount)
    xp = env.xp
    com = env.com
    chain = env.chain
    body: BlockBody
    blk: EthBlock

  suite "Test TxPool with blobhash block":
    test "TxPool addLocal":
      let res = xp.addLocal(PooledTransaction(tx: tx1), force = true)
      check res.isOk
      if res.isErr:
        debugEcho res.error
        return
      let res2 = xp.addLocal(PooledTransaction(tx: tx2), force = true)
      check res2.isOk

    test "TxPool jobCommit":
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

      blk = r.get.blk
      check com.isBlockAfterTtd(blk.header)

      body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles,
        withdrawals: Opt.some(newSeq[Withdrawal]())
      )
      check blk.txs.len == 2

    test "Blobhash persistBlocks":
      let rr = chain.persistBlocks([EthBlock.init(blk.header, body)])
      check rr.isOk()

    test "validate TxPool prevRandao setter":
      var sdb = LedgerRef.init(com.db, blk.header.stateRoot)
      let val = sdb.getStorage(recipient, slot)
      let randao = Hash256(data: val.toBytesBE)
      check randao == prevRandao

    test "feeRecipient rewarded":
      check blk.header.coinbase == feeRecipient
      var sdb = LedgerRef.init(com.db, blk.header.stateRoot)
      let bal = sdb.getBalance(feeRecipient)
      check not bal.isZero

    test "add tx with nonce too low":
      let
        tx3 = env.makeTx(recipient, amount)
        tx4 = env.signTxWithNonce(tx3, AccountNonce(env.nonce-2))
        xp = env.xp

      check xp.smartHead(blk.header)
      let res = xp.addLocal(PooledTransaction(tx: tx4), force = true)
      check res.isOk
      if res.isErr:
        debugEcho res.error
        return

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
        head = com.db.getCanonicalHead()
        timestamp = head.timestamp

      const
        txPerblock = 20
        numBlocks = 10

      # setTraceLevel()

      block:
        for n in 0..<numBlocks:

          for tn in 0..<txPerblock:
            let tx = env.makeTx(recipient, amount)
            # Instead of `add()`, the functions `addRemote()` or `addLocal()`
            # also would do.
            xp.add(PooledTransaction(tx: tx))

          noisy.say "***", "txDB",
            &" n={n}",
            # pending/staged/packed : total/disposed
            &" stats={xp.nItems.pp}"

          timestamp = timestamp + 1
          com.pos.prevRandao = prevRandao
          com.pos.timestamp  = timestamp
          com.pos.feeRecipient = feeRecipient

          let r = xp.assembleBlock()
          if r.isErr:
            debugEcho r.error
            check false
            return

          let blk = r.get.blk
          check com.isBlockAfterTtd(blk.header)

          let body = BlockBody(
            transactions: blk.txs,
            uncles: blk.uncles)

          # Commit to block chain
          check chain.persistBlocks([EthBlock.init(blk.header, body)]).isOk

          # Synchronise TxPool against new chain head, register txs differences.
          # In this particular case, these differences will simply flush the
          # packer bucket.
          check xp.smartHead(blk.header)

          # Move TxPool chain head to new chain head and apply delta jobs
          check xp.nItems.staged == 0
          check xp.nItems.packed == 0

          setErrorLevel() # in case we set trace level

      check com.syncCurrent == 10.BlockNumber
      head = com.db.getBlockHeader(com.syncCurrent)
      let
        sdb = LedgerRef.init(com.db, head.stateRoot)
        expected = u256(txPerblock * numBlocks) * amount
        balance = sdb.getBalance(recipient)
      check balance == expected

proc runGetBlockBodyTest() =
  var
    env = initEnv(Cancun)
    blockTime = EthTime.now()
    parentHeader: BlockHeader
    currentHeader: BlockHeader

  suite "Test get parent transactions after persistBlock":
    test "TxPool create first block":
      let
        tx1 = env.makeTx(recipient, 1.u256)
        tx2 = env.makeTx(recipient, 2.u256)

      check env.xp.addLocal(PooledTransaction(tx: tx1), true).isOk
      check env.xp.addLocal(PooledTransaction(tx: tx2), true).isOk

      env.com.pos.prevRandao = prevRandao
      env.com.pos.feeRecipient = feeRecipient
      env.com.pos.timestamp = blockTime

      let r = env.xp.assembleBlock()
      if r.isErr:
        check false
        return

      let blk = r.get.blk
      check env.chain.persistBlocks([blk]).isOk
      parentHeader = blk.header
      check env.xp.smartHead(parentHeader)
      check blk.transactions.len == 2

    test "TxPool create second block":
      let
        tx1 = env.makeTx(recipient, 3.u256)
        tx2 = env.makeTx(recipient, 4.u256)
        tx3 = env.makeTx(recipient, 5.u256)

      check env.xp.addLocal(PooledTransaction(tx: tx1), true).isOk
      check env.xp.addLocal(PooledTransaction(tx: tx2), true).isOk
      check env.xp.addLocal(PooledTransaction(tx: tx3), true).isOk

      env.com.pos.prevRandao = prevRandao
      env.com.pos.feeRecipient = feeRecipient
      env.com.pos.timestamp = blockTime + 1

      let r = env.xp.assembleBlock()
      if r.isErr:
        check false
        return

      let blk = r.get.blk
      check env.chain.persistBlocks([blk]).isOk
      currentHeader = blk.header
      check env.xp.smartHead(currentHeader)
      check blk.transactions.len == 3

    test "Get current block body":
      var body: BlockBody
      check env.com.db.getBlockBody(currentHeader, body)
      check body.transactions.len == 3
      check env.com.db.getReceipts(currentHeader.receiptsRoot).len == 3
      check env.com.db.getTransactionCount(currentHeader.txRoot) == 3

    test "Get parent block body":
      # Make sure parent baggage doesn't swept away by aristo
      var body: BlockBody
      check env.com.db.getBlockBody(parentHeader, body)
      check body.transactions.len == 2
      check env.com.db.getReceipts(parentHeader.receiptsRoot).len == 2
      check env.com.db.getTransactionCount(parentHeader.txRoot) == 2

proc txPool2Main*() =
  const
    noisy = defined(debug)

  setErrorLevel() # mute logger

  runTxPoolPosTest()
  runTxPoolBlobhashTest()
  noisy.runTxHeadDelta
  runGetBlockBodyTest()

when isMainModule:
  txPool2Main()

# End
