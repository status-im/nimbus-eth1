# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  asynctest, json, strutils, tables, os, typetraits,
  nimcrypto/[hash], nimcrypto/utils as ncrutils, stew/byteutils, times,
  json_rpc/[rpcserver, rpcclient],
  eth/[rlp, keys, p2p/private/p2p_types],
  ../nimbus/rpc/rpc_utils,
  ../nimbus/[constants, transaction, config,
             vm_state, vm_types, version],
  ../nimbus/db/[ledger, storage_types],
  ../nimbus/sync/protocol,
  ../nimbus/core/[tx_pool, chain, executor, executor/executor_helpers, pow/difficulty],
  ../nimbus/utils/utils,
  ../nimbus/common,
  ../nimbus/rpc,
   ./test_helpers, ./macro_assembler, ./rpcclient/eth_api, ./test_block_fixture

const
  zeroAddress = block:
    var rc: EthAddress
    rc

type
  TestEnv = object
    txHash: Hash256
    blockHash: Hash256

proc persistFixtureBlock(chainDB: CoreDbRef) =
  let header = getBlockHeader4514995()
  # Manually inserting header to avoid any parent checks
  chainDB.kvt.put(genericHashKey(header.blockHash).toOpenArray, rlp.encode(header))
  chainDB.addBlockNumberToHashLookup(header)
  discard chainDB.persistTransactions(header.blockNumber, getBlockBody4514995().transactions)
  discard chainDB.persistReceipts(getReceipts4514995())

proc setupEnv(com: CommonRef, signer, ks2: EthAddress, ctx: EthContext): TestEnv =
  var
    parent = com.db.getCanonicalHead()
    acc = ctx.am.getAccount(signer).tryGet()
    blockNumber = 1.toBlockNumber
    parentHash = parent.blockHash

  const code = evmByteCode:
    Push4 "0xDEADBEEF"  # PUSH
    Push1 "0x00"        # MSTORE AT 0x00
    Mstore
    Push1 "0x04"        # RETURN LEN
    Push1 "0x1C"        # RETURN OFFSET at 28
    Return

  let
    vmHeader = BlockHeader(parentHash: parentHash, gasLimit: 5_000_000)
    vmState = BaseVMState.new(
      parent    = BlockHeader(stateRoot: parent.stateRoot),
      header    = vmHeader,
      com       = com)

  vmState.stateDB.setCode(ks2, code)
  vmState.stateDB.addBalance(signer, 9_000_000_000.u256)

  let
    unsignedTx1 = Transaction(
      txType  : TxLegacy,
      nonce   : 0,
      gasPrice: 1_100,
      gasLimit: 70_000,
      value   : 1.u256,
      to      : some(zeroAddress)
    )
    unsignedTx2 = Transaction(
      txType  : TxLegacy,
      nonce   : 1,
      gasPrice: 1_200,
      gasLimit: 70_000,
      value   : 2.u256,
      to      : some(zeroAddress)
    )
    eip155    = com.isEIP155(com.syncCurrent)
    signedTx1 = signTransaction(unsignedTx1, acc.privateKey, com.chainId, eip155)
    signedTx2 = signTransaction(unsignedTx2, acc.privateKey, com.chainId, eip155)
    txs = [signedTx1, signedTx2]
    txRoot = com.db.persistTransactions(blockNumber, txs)

  vmState.receipts = newSeq[Receipt](txs.len)
  vmState.cumulativeGasUsed = 0
  for txIndex, tx in txs:
    let sender = tx.getSender()
    let rc = vmState.processTransaction(tx, sender, vmHeader)
    doAssert(rc.isOk, "Invalid transaction")
    vmState.receipts[txIndex] = makeReceipt(vmState, tx.txType)

  let
    receiptRoot = com.db.persistReceipts(vmState.receipts)
    date        = dateTime(2017, mMar, 30)
    timeStamp   = date.toTime
    difficulty  = com.calcDifficulty(timeStamp, parent)

  # call persist() before we get the rootHash
  vmState.stateDB.persist()

  var header = BlockHeader(
    parentHash  : parentHash,
    #coinbase*:      EthAddress
    stateRoot   : vmState.stateDB.rootHash,
    txRoot      : txRoot,
    receiptRoot : receiptRoot,
    bloom       : createBloom(vmState.receipts),
    difficulty  : difficulty,
    blockNumber : blockNumber,
    gasLimit    : vmState.cumulativeGasUsed + 1_000_000,
    gasUsed     : vmState.cumulativeGasUsed,
    timestamp   : timeStamp
    #extraData:     Blob
    #mixDigest:     Hash256
    #nonce:         BlockNonce
    )

  let uncles = [header]
  header.ommersHash = com.db.persistUncles(uncles)

  discard com.db.persistHeaderToDb(header,
    com.consensus == ConsensusType.POS)
  com.db.persistFixtureBlock()
  result = TestEnv(
    txHash: signedTx1.rlpHash,
    blockHash: header.hash
    )

proc rpcMain*() =
  suite "Remote Procedure Calls":
    # TODO: Include other transports such as Http
    let
      conf = makeTestConfig()
      ctx  = newEthContext()
      ethNode = setupEthNode(conf, ctx, eth)
      com = CommonRef.new(
        newCoreDbRef LegacyDbMemory,
        conf.pruneMode == PruneMode.Full,
        conf.networkId,
        conf.networkParams
      )
      signer: EthAddress = hexToByteArray[20]("0x0e69cde81b1aa07a45c32c6cd85d67229d36bb1b")
      ks2: EthAddress = hexToByteArray[20]("0xa3b2222afa5c987da6ef773fde8d01b9f23d481f")
      ks3: EthAddress = hexToByteArray[20]("0x597176e9a64aad0845d83afdaf698fbeff77703b")

    # disable POS/post Merge feature
    com.setTTD none(DifficultyInt)

    let keyStore = "tests" / "keystore"
    let res = ctx.am.loadKeystores(keyStore)
    if res.isErr:
      debugEcho res.error
    doAssert(res.isOk)

    let acc1 = ctx.am.getAccount(signer).tryGet()
    let unlock = ctx.am.unlockAccount(signer, acc1.keystore["password"].getStr())
    if unlock.isErr:
      debugEcho unlock.error
    doAssert(unlock.isOk)

    com.initializeEmptyDb()
    let env = setupEnv(com, signer, ks2, ctx)

    # Create Ethereum RPCs
    let RPC_PORT = 8545
    var
      rpcServer = newRpcSocketServer(["127.0.0.1:" & $RPC_PORT])
      client = newRpcSocketClient()
      txPool = TxPoolRef.new(com, conf.engineSigner)

    setupCommonRpc(ethNode, conf, rpcServer)
    setupEthRpc(ethNode, ctx, com, txPool, rpcServer)

    # Begin tests
    rpcServer.start()
    waitFor client.connect("127.0.0.1", Port(RPC_PORT))

    # TODO: add more tests here
    test "web3_clientVersion":
      let res = await client.web3_clientVersion()
      check res == NimbusIdent

    test "web3_sha3":
      expect ValueError:
        discard await client.web3_sha3(NimbusName.HexDataStr)

      let data = "0x" & byteutils.toHex(NimbusName.toOpenArrayByte(0, NimbusName.len-1))
      let res = await client.web3_sha3(data.hexDataStr)
      let rawdata = ncrutils.fromHex(data[2 .. ^1])
      let hash = "0x" & $keccakHash(rawdata)
      check hash == res

    test "net_version":
      let res = await client.net_version()
      check res == $conf.networkId

    test "net_listening":
      let res = await client.net_listening()
      let listening = ethNode.peerPool.connectedNodes.len < conf.maxPeers
      check res == listening

    test "net_peerCount":
      let res = await client.net_peerCount()
      let peerCount = ethNode.peerPool.connectedNodes.len
      check isValidHexQuantity res.string
      check res == encodeQuantity(peerCount.uint)

    test "eth_protocolVersion":
      let res = await client.eth_protocolVersion()
      # Use a hard-coded number instead of the same expression as the client,
      # so that bugs introduced via that expression are detected.  Using the
      # same expression as the client can hide issues when the value is wrong
      # in both places.  When the expected value genuinely changes, it'll be
      # obvious.  Just change this number.
      check res == $ethVersion

    test "eth_chainId":
      let res = await client.eth_chainId()
      check res == encodeQuantity(distinctBase(com.chainId))

    test "eth_syncing":
      let res = await client.eth_syncing()
      if res.kind == JBool:
        let syncing = ethNode.peerPool.connectedNodes.len > 0
        check res.getBool() == syncing
      else:
        check res.kind == JObject
        check com.syncStart == UInt256.fromHex(res["startingBlock"].getStr())
        check com.syncCurrent == UInt256.fromHex(res["currentBlock"].getStr())
        check com.syncHighest == UInt256.fromHex(res["highestBlock"].getStr())

    test "eth_coinbase":
      let res = await client.eth_coinbase()
      # currently we don't have miner
      check isValidEthAddress(res.string)
      check res == ethAddressStr(EthAddress.default)

    test "eth_mining":
      let res = await client.eth_mining()
      # currently we don't have miner
      check res == false

    test "eth_hashrate":
      let res = await client.eth_hashrate()
      # currently we don't have miner
      check res == encodeQuantity(0.uint)

    test "eth_gasPrice":
      let res = await client.eth_gasPrice()
      check res.string == "0x47E"

    test "eth_accounts":
      let res = await client.eth_accounts()
      check signer.ethAddressStr in res
      check ks2.ethAddressStr in res
      check ks3.ethAddressStr in res

    test "eth_blockNumber":
      let res = await client.eth_blockNumber()
      check res.string == "0x1"

    test "eth_getBalance":
      let a = await client.eth_getBalance(ethAddressStr("0xfff33a3bd36abdbd412707b8e310d6011454a7ae"), "0x0")
      check a.string == "0x1b1ae4d6e2ef5000000"
      let b = await client.eth_getBalance(ethAddressStr("0xfff4bad596633479a2a29f9a8b3f78eefd07e6ee"), "0x0")
      check b.string == "0x56bc75e2d63100000"
      let c = await client.eth_getBalance(ethAddressStr("0xfff7ac99c8e4feb60c9750054bdc14ce1857f181"), "0x0")
      check c.string == "0x3635c9adc5dea00000"

    test "eth_getStorageAt":
      let res = await client.eth_getStorageAt(ethAddressStr("0xfff33a3bd36abdbd412707b8e310d6011454a7ae"), hexDataStr "0x00", "0x0")
      check hexDataStr(0.u256).string == res.string

    test "eth_getTransactionCount":
      let res = await client.eth_getTransactionCount(ethAddressStr("0xfff7ac99c8e4feb60c9750054bdc14ce1857f181"), "0x0")
      check res.string == "0x0"

    test "eth_getBlockTransactionCountByHash":
      let hash = com.db.getBlockHash(0.toBlockNumber)
      let res = await client.eth_getBlockTransactionCountByHash(hash)
      check res.string == "0x0"

    test "eth_getBlockTransactionCountByNumber":
      let res = await client.eth_getBlockTransactionCountByNumber("0x0")
      check res.string == "0x0"

    test "eth_getUncleCountByBlockHash":
      let hash = com.db.getBlockHash(0.toBlockNumber)
      let res = await client.eth_getUncleCountByBlockHash(hash)
      check res.string == "0x0"

    test "eth_getUncleCountByBlockNumber":
      let res = await client.eth_getUncleCountByBlockNumber("0x0")
      check res.string == "0x0"

    test "eth_getCode":
      let res = await client.eth_getCode(ethAddressStr("0xfff7ac99c8e4feb60c9750054bdc14ce1857f181"), "0x0")
      check res.string == "0x"

    test "eth_sign":
      let msg = "hello world"
      let msgHex = hexDataStr(msg.toOpenArrayByte(0, msg.len-1))

      expect ValueError:
        discard await client.eth_sign(ethAddressStr(ks2), msgHex)

      let res = await client.eth_sign(ethAddressStr(signer), msgHex)
      let sig = Signature.fromHex(res.string).tryGet()

      # now let us try to verify signature
      let msgData  = "\x19Ethereum Signed Message:\n" & $msg.len & msg
      let msgDataHex = hexDataStr(msgData.toOpenArrayByte(0, msgData.len-1))
      let sha3Data = await client.web3_sha3(msgDataHex)
      let msgHash  = hexToByteArray[32](sha3Data)
      let pubkey = recover(sig, SkMessage(msgHash)).tryGet()
      let recoveredAddr = pubkey.toCanonicalAddress()
      check recoveredAddr == signer # verified

    test "eth_signTransaction, eth_sendTransaction, eth_sendRawTransaction":
      var unsignedTx = TxSend(
        source: ethAddressStr(signer),
        to: ethAddressStr(ks2).some,
        gas: encodeQuantity(100000'u).some,
        gasPrice: none(HexQuantityStr),
        value: encodeQuantity(100'u).some,
        data: HexDataStr("0x"),
        nonce: none(HexQuantityStr)
        )

      let signedTxHex = await client.eth_signTransaction(unsignedTx)
      let signedTx = rlp.decode(hexToSeqByte(signedTxHex.string), Transaction)
      check signer == signedTx.getSender() # verified

      let hashAhex = await client.eth_sendTransaction(unsignedTx)
      let hashBhex = await client.eth_sendRawTransaction(signedTxHex)
      check hashAhex.string == hashBhex.string

    test "eth_call":
      var ec = EthCall(
        source: ethAddressStr(signer).some,
        to: ethAddressStr(ks2).some,
        gas: encodeQuantity(100000'u).some,
        gasPrice: none(HexQuantityStr),
        value: encodeQuantity(100'u).some
        )

      let res = await client.eth_call(ec, "latest")
      check hexToByteArray[4](res.string) == hexToByteArray[4]("deadbeef")

    test "eth_estimateGas":
      var ec = EthCall(
        source: ethAddressStr(signer).some,
        to: ethAddressStr(ks3).some,
        gas: encodeQuantity(42000'u).some,
        gasPrice: encodeQuantity(100'u).some,
        value: encodeQuantity(100'u).some
        )

      let res = await client.eth_estimateGas(ec, "latest")
      check hexToInt(res.string, int) == 21000

    test "eth_getBlockByHash":
      let res = await client.eth_getBlockByHash(env.blockHash, true)
      check res.isSome
      check res.get().hash.get() == env.blockHash
      let res2 = await client.eth_getBlockByHash(env.txHash, true)
      check res2.isNone

    test "eth_getBlockByNumber":
      let res = await client.eth_getBlockByNumber("latest", true)
      check res.isSome
      check res.get().hash.get() == env.blockHash
      let res2 = await client.eth_getBlockByNumber($1, true)
      check res2.isNone

    test "eth_getTransactionByHash":
      let res = await client.eth_getTransactionByHash(env.txHash)
      check res.isSome
      check res.get().blockNumber.get().string.hexToInt(int) == 1
      let res2 = await client.eth_getTransactionByHash(env.blockHash)
      check res2.isNone

    test "eth_getTransactionByBlockHashAndIndex":
      let res = await client.eth_getTransactionByBlockHashAndIndex(env.blockHash, encodeQuantity(0))
      check res.isSome
      check res.get().blockNumber.get().string.hexToInt(int) == 1

      let res2 = await client.eth_getTransactionByBlockHashAndIndex(env.blockHash, encodeQuantity(3))
      check res2.isNone

      let res3 = await client.eth_getTransactionByBlockHashAndIndex(env.txHash, encodeQuantity(3))
      check res3.isNone

    test "eth_getTransactionByBlockNumberAndIndex":
      let res = await client.eth_getTransactionByBlockNumberAndIndex("latest", encodeQuantity(1))
      check res.isSome
      check res.get().blockNumber.get().string.hexToInt(int) == 1

      let res2 = await client.eth_getTransactionByBlockNumberAndIndex("latest", encodeQuantity(3))
      check res2.isNone

    test "eth_getTransactionReceipt":
      let res = await client.eth_getTransactionReceipt(env.txHash)
      check res.isSome
      check res.get().blockNumber.string.hexToInt(int) == 1

      let res2 = await client.eth_getTransactionReceipt(env.blockHash)
      check res2.isNone

    test "eth_getUncleByBlockHashAndIndex":
      let res = await client.eth_getUncleByBlockHashAndIndex(env.blockHash, encodeQuantity(0))
      check res.isSome
      check res.get().number.get().string.hexToInt(int) == 1

      let res2 = await client.eth_getUncleByBlockHashAndIndex(env.blockHash, encodeQuantity(1))
      check res2.isNone

      let res3 = await client.eth_getUncleByBlockHashAndIndex(env.txHash, encodeQuantity(0))
      check res3.isNone

    test "eth_getUncleByBlockNumberAndIndex":
      let res = await client.eth_getUncleByBlockNumberAndIndex("latest", encodeQuantity(0))
      check res.isSome
      check res.get().number.get().string.hexToInt(int) == 1

      let res2 = await client.eth_getUncleByBlockNumberAndIndex("latest", encodeQuantity(1))
      check res2.isNone

    test "eth_getLogs by blockhash, no filters":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash
      let filterOptions = FilterOptions(
        blockHash: some(testHash),
        topics: @[]
      )
      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 54

      var i = 0
      for l in logs:
        check:
          l.blockHash.isSome()
          l.blockHash.unsafeGet() == testHash
          fromHex[int](distinctBase(l.logIndex.unsafeGet())) == i
        inc i

    test "eth_getLogs by blockNumber, no filters":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash
      let fBlock: string = distinctBase(encodeQuantity(testHeader.blockNumber))
      let tBlock: string = distinctBase(encodeQuantity(testHeader.blockNumber))
      let filterOptions = FilterOptions(
        fromBlock: some(fBlock),
        toBlock: some(tBlock)
      )
      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 54

      var i = 0
      for l in logs:
        check:
          l.blockHash.isSome()
          l.blockHash.unsafeGet() == testHash
          fromHex[int](distinctBase(l.logIndex.unsafeGet())) == i
        inc i

    test "eth_getLogs by blockhash, filter logs at specific postions":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash

      let topic = hash.fromHex(MDigest[256], "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      let topic1 = hash.fromHex(MDigest[256], "0x000000000000000000000000fdc183d01a793613736cd40a5a578f49add1772b")

      let filterOptions = FilterOptions(
        blockHash: some(testHash),
        topics: @[some(@[topic]), none[seq[Hash256]](), some(@[topic1])]
      )

      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 1


    test "eth_getLogs by blockhash, filter logs at specific postions with or options":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash

      let topic = hash.fromHex(MDigest[256], "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      let topic1 = hash.fromHex(MDigest[256], "0xa64da754fccf55aa65a1f0128a648633fade3884b236e879ee9f64c78df5d5d7")

      let topic2 = hash.fromHex(MDigest[256], "0x000000000000000000000000e16c02eac87920033ac72fc55ee1df3151c75786")
      let topic3 = hash.fromHex(MDigest[256], "0x000000000000000000000000b626a5facc4de1c813f5293ec3be31979f1d1c78")



      let filterOptions = FilterOptions(
        blockHash: some(testHash),
        topics: @[
          some(@[topic, topic1]),
          some(@[topic2, topic3])
        ]
      )

      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 2

    rpcServer.stop()
    rpcServer.close()

when isMainModule:
  rpcMain()
