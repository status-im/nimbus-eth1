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
    sender = TxSender.new(conf.networkParams)
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

proc txPoolMain*() =
  suite "TxPool test suite":
    loadKzgTrustedSetup().expect("KZG trusted setup loaded")
    let
      env = initEnv(Cancun)
      xp = env.xp
      mx = env.sender
      chain = env.chain
      com = env.com

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
      let rc = xp.addTx(ptx)
      check rc.isErr
      check rc.error == txErrorInvalidBlob
      check xp.len == 0

    test "Bad chainId":
      let acc = mx.getAccount(1)
      let tc = BaseTx(
        gasLimit: 75000
      )
      var ptx = mx.makeTx(tc, 0)
      let ccid = ptx.tx.chainId.uint64
      let cid = Opt.some(ChainId(ccid.not))
      ptx.tx = mx.customizeTransaction(acc, ptx.tx, CustomTx(chainId: cid))
      let rc = xp.addTx(ptx)
      check rc.isErr
      check rc.error == txErrorChainIdMismatch
      check xp.len == 0

    test "Basic validation error, gas limit too low":
      let tc = BaseTx(
        gasLimit: 18000
      )
      var ptx = mx.makeTx(tc, 0)
      let rc = xp.addTx(ptx)
      check rc.isErr
      check rc.error == txErrorBasicValidation
      check xp.len == 0

    test "Known tx":
      let tc = BaseTx(
        gasLimit: 75000
      )
      let ptx = mx.makeNextTx(tc)
      check xp.addTx(ptx).isOk
      let rc = xp.addTx(ptx)
      check rc.isErr
      check rc.error == txErrorAlreadyKnown
      check xp.len == 1

      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = com.pos.timestamp + 1
      let bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 1
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return
      xp.removeNewBlockTxs(bundle.blk)
      check xp.len == 0

    test "nonce too small":
      let tc = BaseTx(
        gasLimit: 75000
      )
      let ptx = mx.makeNextTx(tc)
      check xp.addTx(ptx).isOk
      check xp.len == 1

      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = com.pos.timestamp + 1
      let bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 1
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      xp.removeNewBlockTxs(bundle.blk)
      check xp.len == 0

      let rc = xp.addTx(ptx)
      check rc.isErr
      check rc.error == txErrorNonceTooSmall
      check xp.len == 0

    test "nonce gap after account nonce":
      let acc = mx.getAccount(13)
      let tc = BaseTx(
        gasLimit: 75000
      )
      let ptx1 = mx.makeTx(tc, acc, 1)
      check xp.addTx(ptx1).isOk
      check xp.len == 1

      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = com.pos.timestamp + 1
      var bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 0
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      let ptx0 = mx.makeTx(tc, acc, 0)
      check xp.addTx(ptx0).isOk
      check xp.len == 2

      com.pos.timestamp = com.pos.timestamp + 1
      bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 2
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      xp.removeNewBlockTxs(bundle.blk)
      check xp.len == 0

    test "nonce gap in the middle of nonces":
      let acc = mx.getAccount(14)
      let tc = BaseTx(
        gasLimit: 75000
      )

      let ptx0 = mx.makeTx(tc, acc, 0)
      check xp.addTx(ptx0).isOk
      check xp.len == 1

      let ptx2 = mx.makeTx(tc, acc, 2)
      check xp.addTx(ptx2).isOk
      check xp.len == 2

      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = com.pos.timestamp + 1
      var bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 1
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      xp.removeNewBlockTxs(bundle.blk)
      check xp.len == 1

      let ptx1 = mx.makeTx(tc, acc, 1)
      check xp.addTx(ptx1).isOk
      check xp.len == 2

      com.pos.timestamp = com.pos.timestamp + 1
      bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 2
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      xp.removeNewBlockTxs(bundle.blk)
      check xp.len == 0

    test "supersede existing tx":
      let acc = mx.getAccount(15)
      let tc = BaseTx(
        gasLimit: 75000
      )

      var ptx = mx.makeTx(tc, acc, 0)
      check xp.addTx(ptx).isOk
      check xp.len == 1

      let oldPrice = ptx.tx.gasPrice
      ptx.tx = mx.customizeTransaction(acc, ptx.tx,
        CustomTx(gasPriceOrGasFeeCap: Opt.some(oldPrice*2)))
      check xp.addTx(ptx).isOk
      check xp.len == 1

      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = com.pos.timestamp + 1
      var bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 1
      check bundle.blk.transactions[0].gasPrice == oldPrice*2

      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      xp.removeNewBlockTxs(bundle.blk)
      check xp.len == 0


    test "removeNewBlockTxs after two blocks":
      let tc = BaseTx(
        gasLimit: 75000
      )

      var ptx = mx.makeNextTx(tc)
      check xp.addTx(ptx).isOk
      check xp.len == 1

      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = com.pos.timestamp + 1
      var bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 1
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      ptx = mx.makeNextTx(tc)
      check xp.addTx(ptx).isOk
      check xp.len == 2

      com.pos.timestamp = com.pos.timestamp + 1
      bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      check bundle.blk.transactions.len == 1
      chain.importBlock(bundle.blk).isOkOr:
        check false
        debugEcho error
        return

      xp.removeNewBlockTxs(bundle.blk)
      check xp.len == 0

    test "max transactions per account":
      let acc = mx.getAccount(16)
      let tc = BaseTx(
        gasLimit: 75000
      )

      const MAX_TXS_GENERATED = 100
      for i in 0..MAX_TXS_GENERATED-2:
        let ptx = mx.makeTx(tc, acc, i.AccountNonce)
        check xp.addTx(ptx).isOk
        check xp.len == i + 1

      var ptx = mx.makeTx(tc, acc, MAX_TXS_GENERATED-1)
      check xp.addTx(ptx).isOk
      check xp.len == MAX_TXS_GENERATED

      var ptxMax = mx.makeTx(tc, acc, MAX_TXS_GENERATED)
      let rc = xp.addTx(ptxMax)
      check rc.isErr
      check rc.error == txErrorSenderMaxTxs
      check xp.len == MAX_TXS_GENERATED

      # superseding not hit sender max txs
      let oldPrice = ptx.tx.gasPrice
      ptx.tx = mx.customizeTransaction(acc, ptx.tx,
        CustomTx(gasPriceOrGasFeeCap: Opt.some(oldPrice*2)))
      xp.addTx(ptx).isOkOr:
        debugEcho error
        check false
        return

      check xp.len == MAX_TXS_GENERATED

      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient

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

when isMainModule:
  txPoolMain()
