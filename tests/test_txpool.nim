# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common/keys,
  results,
  unittest2,
  ../hive_integration/nodocker/engine/tx_sender,
  ../hive_integration/nodocker/engine/cancun/blobs,
  ../nimbus/db/ledger,
  ../nimbus/core/chain,
  ../nimbus/core/eip4844,
  ../nimbus/[config, transaction, constants],
  ../nimbus/core/tx_pool,
  ../nimbus/core/tx_pool/tx_desc,
  ../nimbus/core/casper,
  ../nimbus/common/common,
  ../nimbus/utils/utils

const
  genesisFile = "tests/customgenesis/merge.json"
  feeRecipient = address"0000000000000000000000000000000000000212"
  recipient = address"0000000000000000000000000000000000000213"
  prevRandao = Bytes32 EMPTY_UNCLE_HASH

type
  TestEnv = object
    conf  : NimbusConf
    com   : CommonRef
    chain : ForkedChainRef
    xp    : TxPoolRef
    sender: TxSender

  CustomTx = CustomTransactionData

proc initEnv(envFork: HardFork): TestEnv =
  var conf = makeConfig(
    @["--custom-network:" & genesisFile]
  )

  doAssert envFork >= MergeFork

  if envFork >= MergeFork:
    conf.networkParams.config.mergeNetsplitBlock = Opt.some(0'u64)

  if envFork >= Shanghai:
    conf.networkParams.config.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    conf.networkParams.config.cancunTime = Opt.some(0.EthTime)

  if envFork >= Prague:
    conf.networkParams.config.pragueTime = Opt.some(0.EthTime)

  let
    # create the sender first, because it will modify networkParams
    sender = TxSender.new(conf.networkParams, 30)
    com    = CommonRef.new(newCoreDbRef DefaultDbMemory,
               nil, conf.networkId, conf.networkParams)
    chain  = ForkedChainRef.init(com)

  TestEnv(
    conf  : conf,
    com   : com,
    chain : chain,
    xp    : TxPoolRef.new(chain),
    sender: sender
  )

template checkAddTx(xp, tx, errorCode) =
  let prevCount = xp.len
  let rc = xp.addTx(tx)
  check rc.isErr == true
  if rc.isErr:
    check rc.error == errorCode
  check xp.len == prevCount

template checkAddTx(xp, tx) =
  let expCount = xp.len + 1
  let rc = xp.addTx(tx)
  check rc.isOk == true
  if rc.isErr:
    debugEcho "ADD TX: ", rc.error
  check xp.len == expCount

template checkAddTxSupersede(xp, tx) =
  let prevCount = xp.len
  let rc = xp.addTx(tx)
  check rc.isOk == true
  if rc.isErr:
    debugEcho "ADD TX SUPERSEDE: ", rc.error
  check xp.len == prevCount

template checkAssembleBlock(xp, expCount): auto =
  xp.com.pos.timestamp = xp.com.pos.timestamp + 1
  let rc = xp.assembleBlock()
  check rc.isOk == true
  if rc.isErr:
    debugEcho "ASSEMBLE BLOCK: ", rc.error
  if rc.isOk:
    check rc.value.blk.transactions.len == expCount
  rc.get

template checkImportBlock(xp: TxPoolRef, bundle: AssembledBlock) =
  let rc = xp.chain.importBlock(bundle.blk)
  check rc.isOk == true
  if rc.isErr:
    debugEcho "IMPORT BLOCK: ", rc.error

template checkImportBlock(xp: TxPoolRef, expCount: int, expRem: int) =
  let bundle = checkAssembleBlock(xp, expCount)
  checkImportBlock(xp, bundle)
  xp.removeNewBlockTxs(bundle.blk)
  check xp.len == expRem

template checkImportBlock(xp: TxPoolRef, expCount: int) =
  let bundle = checkAssembleBlock(xp, expCount)
  checkImportBlock(xp, bundle)

template checkImportBlock(xp: TxPoolRef, bundle: AssembledBlock, expRem: int) =
  checkImportBlock(xp, bundle)
  xp.removeNewBlockTxs(bundle.blk)
  check xp.len == expRem

proc txPoolMain*() =
  suite "TxPool test suite":
    loadKzgTrustedSetup().expect("KZG trusted setup loaded")
    let
      env = initEnv(Cancun)
      xp = env.xp
      mx = env.sender
      chain = env.chain
      com = env.com

    com.pos.prevRandao = prevRandao
    com.pos.feeRecipient = feeRecipient
    com.pos.timestamp = EthTime.now()

    test "Bad blob tx":
      let acc = mx.getAccount(7)
      let tc = BlobTx(
        txType: Opt.some(TxEip4844),
        gasLimit: 75000,
        recipient: Opt.some(acc.address),
        blobID: 0.BlobID
      )
      var ptx = mx.makeTx(tc, 0)
      var z = ptx.networkPayload.blobs[0]
      z[0] = not z[0]
      ptx.networkPayload.blobs[0] = z
      xp.checkAddTx(ptx, txErrorInvalidBlob)

    test "Bad chainId":
      let acc = mx.getAccount(1)
      let tc = BaseTx(
        gasLimit: 75000
      )
      var ptx = mx.makeTx(tc, 0)
      let ccid = ptx.tx.chainId.uint64
      let cid = Opt.some(ChainId(ccid.not))
      ptx.tx = mx.customizeTransaction(acc, ptx.tx, CustomTx(chainId: cid))
      xp.checkAddTx(ptx, txErrorChainIdMismatch)

    test "Basic validation error, gas limit too low":
      let tc = BaseTx(
        gasLimit: 18000
      )
      let ptx = mx.makeTx(tc, 0)
      xp.checkAddTx(ptx, txErrorBasicValidation)

    test "Known tx":
      let tc = BaseTx(
        gasLimit: 75000
      )
      let ptx = mx.makeNextTx(tc)
      xp.checkAddTx(ptx)
      xp.checkAddTx(ptx, txErrorAlreadyKnown)
      xp.checkImportBlock(1, 0)

    test "nonce too small":
      let tc = BaseTx(
        gasLimit: 75000
      )
      let ptx = mx.makeNextTx(tc)
      xp.checkAddTx(ptx)
      xp.checkImportBlock(1, 0)
      xp.checkAddTx(ptx, txErrorNonceTooSmall)

    test "nonce gap after account nonce":
      let acc = mx.getAccount(13)
      let tc = BaseTx(
        gasLimit: 75000
      )
      let ptx1 = mx.makeTx(tc, acc, 1)
      xp.checkAddTx(ptx1)

      xp.checkImportBlock(0)

      let ptx0 = mx.makeTx(tc, acc, 0)
      xp.checkAddTx(ptx0)

      xp.checkImportBlock(2, 0)

    test "nonce gap in the middle of nonces":
      let acc = mx.getAccount(14)
      let tc = BaseTx(
        gasLimit: 75000
      )

      let ptx0 = mx.makeTx(tc, acc, 0)
      xp.checkAddTx(ptx0)

      let ptx2 = mx.makeTx(tc, acc, 2)
      xp.checkAddTx(ptx2)

      xp.checkImportBlock(1, 1)

      let ptx1 = mx.makeTx(tc, acc, 1)
      xp.checkAddTx(ptx1)

      xp.checkImportBlock(2, 0)

    test "supersede existing tx":
      let acc = mx.getAccount(15)
      let tc = BaseTx(
        txType: Opt.some(TxLegacy),
        gasLimit: 75000
      )

      var ptx = mx.makeTx(tc, acc, 0)
      xp.checkAddTx(ptx)

      let oldPrice = ptx.tx.gasPrice
      ptx.tx = mx.customizeTransaction(acc, ptx.tx,
        CustomTx(gasPriceOrGasFeeCap: Opt.some(oldPrice*2)))
      xp.checkAddTxSupersede(ptx)

      let bundle = xp.checkAssembleBlock(1)
      check bundle.blk.transactions[0].gasPrice == oldPrice*2
      xp.checkImportBlock(bundle, 0)

    test "removeNewBlockTxs after two blocks":
      let tc = BaseTx(
        gasLimit: 75000
      )

      var ptx = mx.makeNextTx(tc)
      xp.checkAddTx(ptx)

      xp.checkImportBlock(1)

      ptx = mx.makeNextTx(tc)
      xp.checkAddTx(ptx)

      xp.checkImportBlock(1, 0)

    test "max transactions per account":
      let acc = mx.getAccount(16)
      let tc = BaseTx(
        txType: Opt.some(TxLegacy),
        gasLimit: 75000
      )

      const MAX_TXS_GENERATED = 100
      for i in 0..MAX_TXS_GENERATED-2:
        let ptx = mx.makeTx(tc, acc, i.AccountNonce)
        xp.checkAddTx(ptx)

      var ptx = mx.makeTx(tc, acc, MAX_TXS_GENERATED-1)
      xp.checkAddTx(ptx)

      let ptxMax = mx.makeTx(tc, acc, MAX_TXS_GENERATED)
      xp.checkAddTx(ptxMax, txErrorSenderMaxTxs)

      # superseding not hit sender max txs
      let oldPrice = ptx.tx.gasPrice
      ptx.tx = mx.customizeTransaction(acc, ptx.tx,
        CustomTx(gasPriceOrGasFeeCap: Opt.some(oldPrice*2)))
      xp.checkAddTxSupersede(ptx)

      var numTxsPacked = 0
      while numTxsPacked < MAX_TXS_GENERATED:
        com.pos.timestamp = com.pos.timestamp + 1
        let bundle = xp.assembleBlock().valueOr:
          debugEcho error
          check false
          return

        numTxsPacked += bundle.blk.transactions.len

        chain.importBlock(bundle.blk).isOkOr:
          check false
          debugEcho error
          return

        xp.removeNewBlockTxs(bundle.blk)

      check xp.len == 0

    test "auto remove lower nonces":
      let xp2 = TxPoolRef.new(chain)
      let acc = mx.getAccount(17)
      let tc = BaseTx(
        gasLimit: 75000
      )

      let ptx0 = mx.makeTx(tc, acc, 0)
      xp.checkAddTx(ptx0)
      xp2.checkAddTx(ptx0)

      let ptx1 = mx.makeTx(tc, acc, 1)
      xp.checkAddTx(ptx1)
      xp2.checkAddTx(ptx1)

      let ptx2 = mx.makeTx(tc, acc, 2)
      xp.checkAddTx(ptx2)

      xp2.checkImportBlock(2, 0)
      xp.checkImportBlock(1, 0)

    test "mixed type of transactions":
      let acc = mx.getAccount(18)
      let
        tc1 = BaseTx(
          txType: Opt.some(TxLegacy),
          gasLimit: 75000
        )
        tc2 = BaseTx(
          txType: Opt.some(TxEip1559),
          gasLimit: 75000
        )
        tc3 = BaseTx(
          txType: Opt.some(TxEip4844),
          recipient: Opt.some(recipient),
          gasLimit: 75000
        )

      let ptx0 = mx.makeTx(tc1, acc, 0)
      let ptx1 = mx.makeTx(tc2, acc, 1)
      let ptx2 = mx.makeTx(tc3, acc, 2)

      xp.checkAddTx(ptx0)
      xp.checkAddTx(ptx1)
      xp.checkAddTx(ptx2)
      xp.checkImportBlock(3, 0)

when isMainModule:
  txPoolMain()
