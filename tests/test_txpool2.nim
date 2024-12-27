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
  ./macro_assembler

const
  genesisFile = "tests/customgenesis/merge.json"

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
    @["--custom-network:" & genesisFile]
  )

  conf.networkParams.genesis.alloc[recipient] = GenesisAccount(code: contractCode)

  if envFork >= MergeFork:
    conf.networkParams.config.mergeNetsplitBlock = Opt.some(0'u64)
    conf.networkParams.config.terminalTotalDifficulty = Opt.some(100.u256)

  if envFork >= Shanghai:
    conf.networkParams.config.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    conf.networkParams.config.cancunTime = Opt.some(0.EthTime)

  if envFork >= Prague:
    conf.networkParams.config.pragueTime = Opt.some(0.EthTime)

  let
    com   = CommonRef.new(newCoreDbRef DefaultDbMemory,
              nil, conf.networkId, conf.networkParams)
    chain = ForkedChainRef.init(com)

  TestEnv(
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

template runTxPoolPosTest() =
  test "Test TxPool with PoS block":
    var
      env = initEnv(MergeFork)
      tx = env.makeTx(recipient, amount)
      xp = env.xp
      com = env.com
      chain = env.chain

    check xp.addTx(tx).isOk
    check xp.len == 1

    # generate block
    com.pos.prevRandao = prevRandao
    com.pos.feeRecipient = feeRecipient
    com.pos.timestamp = EthTime.now()

    let bundle = xp.assembleBlock().valueOr:
      debugEcho error
      check false
      return

    let blk = bundle.blk
    check blk.transactions.len == 1

    # import block
    chain.importBlock(blk).isOkOr:
      debugEcho error
      check false
      return

    let
      sdb = LedgerRef.init(com.db.baseTxFrame())
      val = sdb.getStorage(recipient, slot)
      randao = Bytes32(val.toBytesBE)
      bal = sdb.getBalance(feeRecipient)

    check randao == prevRandao
    check blk.header.coinbase == feeRecipient
    check not bal.isZero

template runTxPoolBlobhashTest() =
  test "Test TxPool with blobhash block":
    var
      env = initEnv(Cancun)
      tx1 = env.createPooledTransactionWithBlob(recipient, amount)
      tx2 = env.createPooledTransactionWithBlob(recipient, amount)
      xp = env.xp
      com = env.com
      chain = env.chain

    check xp.addTx(tx1).isOk
    check xp.addTx(tx2).isOk
    check xp.len == 2

    # generate block
    com.pos.prevRandao = prevRandao
    com.pos.feeRecipient = feeRecipient
    com.pos.timestamp = EthTime.now()

    let bundle = xp.assembleBlock().valueOr:
      debugEcho error
      check false
      return

    let blk = bundle.blk
    check blk.transactions.len == 2

    let
      gasUsed1 = xp.vmState.receipts[0].cumulativeGasUsed
      gasUsed2 = xp.vmState.receipts[1].cumulativeGasUsed - gasUsed1
      totalBlobGasUsed = tx1.tx.getTotalBlobGas + tx2.tx.getTotalBlobGas
      blockValue =
        gasUsed1.u256 * tx1.tx.effectiveGasTip(blk.header.baseFeePerGas).u256 +
        gasUsed2.u256 * tx2.tx.effectiveGasTip(blk.header.baseFeePerGas).u256

    check blockValue == bundle.blockValue
    check totalBlobGasUsed == blk.header.blobGasUsed.get()

    chain.importBlock(blk).isOkOr:
      debugEcho error
      check false
      return

    let
      sdb = LedgerRef.init(com.db.baseTxFrame())
      val = sdb.getStorage(recipient, slot)
      randao = Bytes32(val.toBytesBE)
      bal = sdb.getBalance(feeRecipient)

    check randao == prevRandao
    check blk.header.coinbase == feeRecipient
    check not bal.isZero

    let
      tx3 = env.makeTx(recipient, amount)
      tx4 = env.signTxWithNonce(tx3, AccountNonce(env.nonce - 2))

    xp.removeNewBlockTxs(blk)
    let rc = xp.addTx(tx4)
    check rc.isErr
    check rc.error == txErrorNonceTooSmall

template runTxHeadDelta() =
  ## see github.com/status-im/nimbus-eth1/issues/1031
  test "TxPool: Synthesising blocks (covers issue #1031)":
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

    for n in 0 ..< numBlocks:
      for tn in 0 ..< txPerblock:
        let tx = env.makeTx(recipient, amount)
        check xp.addTx(tx).isOk

      timestamp = timestamp + 1
      com.pos.prevRandao = prevRandao
      com.pos.timestamp = timestamp
      com.pos.feeRecipient = feeRecipient

      let bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      let blk = bundle.blk
      # Commit to block chain
      chain.importBlock(blk).isOkOr:
        debugEcho error
        check false
        return

      # Synchronise TxPool against new chain head, register txs differences.
      # In this particular case, these differences will simply flush the
      # packer bucket.
      xp.removeNewBlockTxs(blk)

      # Move TxPool chain head to new chain head and apply delta jobs
      check xp.len == 0

    check com.syncCurrent == 10.BlockNumber
    head = chain.headerByNumber(com.syncCurrent).expect("block header exists")
    let
      sdb = LedgerRef.init(com.db.baseTxFrame())
      expected = u256(txPerblock * numBlocks) * amount
      balance = sdb.getBalance(recipient)
    check balance == expected

template runGetBlockBodyTest() =
  test "Test get parent transactions after persistBlock":
    var
      env = initEnv(Cancun)
      blockTime = EthTime.now()

    let
      tx1 = env.makeTx(recipient, 1.u256)
      tx2 = env.makeTx(recipient, 2.u256)

    check env.xp.addTx(tx1).isOk
    check env.xp.addTx(tx2).isOk
    check env.xp.len == 2

    env.com.pos.prevRandao = prevRandao
    env.com.pos.feeRecipient = feeRecipient
    env.com.pos.timestamp = blockTime

    let bundle = env.xp.assembleBlock().valueOr:
      debugEcho error
      check false
      return

    let blk = bundle.blk
    check env.chain.importBlock(blk).isOk
    env.xp.removeNewBlockTxs(blk)
    check blk.transactions.len == 2

    let
      tx3 = env.makeTx(recipient, 3.u256)
      tx4 = env.makeTx(recipient, 4.u256)
      tx5 = env.makeTx(recipient, 5.u256)

    check env.xp.addTx(tx3).isOk
    check env.xp.addTx(tx4).isOk
    check env.xp.addTx(tx5).isOk
    check env.xp.len == 3

    env.com.pos.prevRandao = prevRandao
    env.com.pos.feeRecipient = feeRecipient
    env.com.pos.timestamp = blockTime + 1

    let bundle2 = env.xp.assembleBlock().valueOr:
      debugEcho error
      check false
      return

    let blk2 = bundle2.blk
    check blk2.transactions.len == 3
    check env.chain.importBlock(blk2).isOk
    env.xp.removeNewBlockTxs(blk2)

    let currHash = blk2.header.blockHash
    check env.chain.forkChoice(currHash, currHash).isOk

proc txPool2Main*() =
  suite "TxPool test suite":
    loadKzgTrustedSetup().expect("KZG trusted setup loaded")
    runTxPoolPosTest()
    runTxPoolBlobhashTest()
    runTxHeadDelta()
    runGetBlockBodyTest()

when isMainModule:
  txPool2Main()

# End
