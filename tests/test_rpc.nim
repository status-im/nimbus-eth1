# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, os, typetraits, times, sequtils],
  asynctest, web3/eth_api,
  stew/byteutils,
  json_rpc/[rpcserver, rpcclient],
  nimcrypto/[keccak, hash],
  eth/[rlp, keys, trie/hexary_proof_verification],
  ../nimbus/[constants, transaction, config, vm_state, vm_types, version],
  ../nimbus/db/[ledger, storage_types],
  ../nimbus/sync/protocol,
  ../nimbus/core/[tx_pool, chain, executor, executor/executor_helpers, pow/difficulty],
  ../nimbus/utils/utils,
  ../nimbus/common,
  ../nimbus/rpc,
  ../nimbus/rpc/rpc_types,
  ../nimbus/beacon/web3_eth_conv,
   ./test_helpers,
   ./macro_assembler,
   ./test_block_fixture

const
  zeroAddress = block:
    var rc: EthAddress
    rc

type
  Hash256 = common.Hash256
  BlockHeader = common.BlockHeader

  TestEnv = object
    txHash: Hash256
    blockHash: Hash256

func ethAddr(x: string): EthAddress =
  hexToByteArray[20](x)

func w3Addr(x: string): Web3Address =
  w3Addr hexToByteArray[20](x)

func w3Hash(x: string): Web3Hash =
  Web3Hash hexToByteArray[32](x)

func zeroHash(): Web3Hash =
  w3Hash("0x0000000000000000000000000000000000000000000000000000000000000000")

func emptyCodeHash(): Web3Hash =
  w3Hash("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

func emptyStorageHash(): Web3Hash =
  w3Hash("0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421")

proc verifyAccountProof(trustedStateRoot: Web3Hash, res: ProofResponse): MptProofVerificationResult =
  let
    key = toSeq(keccakHash(res.address.ethAddr).data)
    value = rlp.encode(Account(
        nonce: res.nonce.uint64,
        balance: res.balance,
        storageRoot: fromHex(Hash256, res.storageHash.toHex()),
        codeHash: fromHex(Hash256, res.codeHash.toHex())))

  verifyMptProof(
    seq[seq[byte]](res.accountProof),
    fromHex(KeccakHash, trustedStateRoot.toHex()),
    key,
    value)

proc verifySlotProof(trustedStorageRoot: Web3Hash, slot: StorageProof): MptProofVerificationResult =
  let
    key = toSeq(keccakHash(toBytesBE(slot.key)).data)
    value = rlp.encode(slot.value)

  verifyMptProof(
    seq[seq[byte]](slot.proof),
    fromHex(KeccakHash, trustedStorageRoot.toHex()),
    key,
    value)

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
  vmState.stateDB.addBalance(
    signer, 1.u256 * 1_000_000_000.u256 * 1_000_000_000.u256)  # 1 ETH

  # Test data created for eth_getProof tests
  let regularAcc = ethAddr("0x0000000000000000000000000000000000000001")
  vmState.stateDB.addBalance(regularAcc, 2_000_000_000.u256)
  vmState.stateDB.setNonce(regularAcc, 1.uint64)

  let contractAccWithStorage = ethAddr("0x0000000000000000000000000000000000000002")
  vmState.stateDB.addBalance(contractAccWithStorage, 1_000_000_000.u256)
  vmState.stateDB.setNonce(contractAccWithStorage, 2.uint64)
  vmState.stateDB.setCode(contractAccWithStorage, code)
  vmState.stateDB.setStorage(contractAccWithStorage, u256(0), u256(1234))
  vmState.stateDB.setStorage(contractAccWithStorage, u256(1), u256(2345))

  let contractAccNoStorage = ethAddr("0x0000000000000000000000000000000000000003")
  vmState.stateDB.setCode(contractAccNoStorage, code)


  let
    unsignedTx1 = Transaction(
      txType  : TxLegacy,
      nonce   : 0,
      gasPrice: 30_000_000_000,
      gasLimit: 70_000,
      value   : 1.u256,
      to      : some(zeroAddress)
    )
    unsignedTx2 = Transaction(
      txType  : TxLegacy,
      nonce   : 1,
      gasPrice: 30_000_000_100,
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
    doAssert(rc.isOk, "Invalid transaction: " & rc.error)
    vmState.receipts[txIndex] = makeReceipt(vmState, tx.txType)

  let
    receiptRoot = com.db.persistReceipts(vmState.receipts)
    date        = dateTime(2017, mMar, 30)
    timeStamp   = date.toTime.toUnix.EthTime
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
        newCoreDbRef DefaultDbMemory,
        conf.networkId,
        conf.networkParams
      )
      signer = ethAddr("0x0e69cde81b1aa07a45c32c6cd85d67229d36bb1b")
      ks2 = ethAddr("0xa3b2222afa5c987da6ef773fde8d01b9f23d481f")
      ks3 = ethAddr("0x597176e9a64aad0845d83afdaf698fbeff77703b")

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
    let RPC_PORT = 0 # let the OS choose a port
    var
      rpcServer = newRpcSocketServer(["127.0.0.1:" & $RPC_PORT])
      client = newRpcSocketClient()
      txPool = TxPoolRef.new(com, conf.engineSigner)
      oracle = Oracle.new(com)

    setupCommonRpc(ethNode, conf, rpcServer)
    setupEthRpc(ethNode, ctx, com, txPool, oracle, rpcServer)

    # Begin tests
    rpcServer.start()
    waitFor client.connect("127.0.0.1", rpcServer.localAddress[0].port)

    # TODO: add more tests here
    test "web3_clientVersion":
      let res = await client.web3_clientVersion()
      check res == NimbusIdent

    test "web3_sha3":
      let data = @(NimbusName.toOpenArrayByte(0, NimbusName.len-1))
      let res = await client.web3_sha3(data)
      let hash = keccakHash(data)
      check hash == ethHash res

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
      check res == w3Qty(peerCount)

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
      check res == w3Qty(distinctBase(com.chainId))

    test "eth_syncing":
      let res = await client.eth_syncing()
      if res.syncing == false:
        let syncing = ethNode.peerPool.connectedNodes.len > 0
        check syncing == false
      else:
        check com.syncStart == res.syncObject.startingBlock.uint64.u256
        check com.syncCurrent == res.syncObject.currentBlock.uint64.u256
        check com.syncHighest == res.syncObject.highestBlock.uint64.u256

    test "eth_coinbase":
      let res = await client.eth_coinbase()
      # currently we don't have miner
      check res == w3Address()

    test "eth_mining":
      let res = await client.eth_mining()
      # currently we don't have miner
      check res == false

    test "eth_hashrate":
      let res = await client.eth_hashrate()
      # currently we don't have miner
      check res == w3Qty(0'u64)

    test "eth_gasPrice":
      let res = await client.eth_gasPrice()
      check res == w3Qty(30_000_000_050)  # Avg of `unsignedTx1` / `unsignedTx2`

    test "eth_accounts":
      let res = await client.eth_accounts()
      check signer.w3Addr in res
      check ks2.w3Addr in res
      check ks3.w3Addr in res

    test "eth_blockNumber":
      let res = await client.eth_blockNumber()
      check res == w3Qty(0x1'u64)

    test "eth_getBalance":
      let a = await client.eth_getBalance(w3Addr("0xfff33a3bd36abdbd412707b8e310d6011454a7ae"), blockId(0'u64))
      check a == UInt256.fromHex("0x1b1ae4d6e2ef5000000")
      let b = await client.eth_getBalance(w3Addr("0xfff4bad596633479a2a29f9a8b3f78eefd07e6ee"), blockId(0'u64))
      check b == UInt256.fromHex("0x56bc75e2d63100000")
      let c = await client.eth_getBalance(w3Addr("0xfff7ac99c8e4feb60c9750054bdc14ce1857f181"), blockId(0'u64))
      check c == UInt256.fromHex("0x3635c9adc5dea00000")

    test "eth_getStorageAt":
      let res = await client.eth_getStorageAt(w3Addr("0xfff33a3bd36abdbd412707b8e310d6011454a7ae"), 0.u256, blockId(0'u64))
      check w3Hash() == res

    test "eth_getTransactionCount":
      let res = await client.eth_getTransactionCount(w3Addr("0xfff7ac99c8e4feb60c9750054bdc14ce1857f181"), blockId(0'u64))
      check res == w3Qty(0'u64)

    test "eth_getBlockTransactionCountByHash":
      let hash = com.db.getBlockHash(0.toBlockNumber)
      let res = await client.eth_getBlockTransactionCountByHash(w3Hash hash)
      check res == w3Qty(0'u64)

    test "eth_getBlockTransactionCountByNumber":
      let res = await client.eth_getBlockTransactionCountByNumber(blockId(0'u64))
      check res == w3Qty(0'u64)

    test "eth_getUncleCountByBlockHash":
      let hash = com.db.getBlockHash(0.toBlockNumber)
      let res = await client.eth_getUncleCountByBlockHash(w3Hash hash)
      check res == w3Qty(0'u64)

    test "eth_getUncleCountByBlockNumber":
      let res = await client.eth_getUncleCountByBlockNumber(blockId(0'u64))
      check res == w3Qty(0'u64)

    test "eth_getCode":
      let res = await client.eth_getCode(w3Addr("0xfff7ac99c8e4feb60c9750054bdc14ce1857f181"), blockId(0'u64))
      check res.len == 0

    test "eth_sign":
      let msg = "hello world"
      let msgBytes = @(msg.toOpenArrayByte(0, msg.len-1))

      expect JsonRpcError:
        discard await client.eth_sign(w3Addr(ks2), msgBytes)

      let res = await client.eth_sign(w3Addr(signer), msgBytes)
      let sig = Signature.fromRaw(res).tryGet()

      # now let us try to verify signature
      let msgData  = "\x19Ethereum Signed Message:\n" & $msg.len & msg
      let msgDataBytes = @(msgData.toOpenArrayByte(0, msgData.len-1))
      let msgHash = await client.web3_sha3(msgDataBytes)
      let pubkey = recover(sig, SkMessage(msgHash.bytes)).tryGet()
      let recoveredAddr = pubkey.toCanonicalAddress()
      check recoveredAddr == signer # verified

    test "eth_signTransaction, eth_sendTransaction, eth_sendRawTransaction":
      var unsignedTx = TransactionArgs(
        `from`: w3Addr(signer).some,
        to: w3Addr(ks2).some,
        gas: w3Qty(100000'u).some,
        gasPrice: none(Quantity),
        value: some 100.u256,
        nonce: none(Quantity)
        )

      let signedTxBytes = await client.eth_signTransaction(unsignedTx)
      let signedTx = rlp.decode(signedTxBytes, Transaction)
      check signer == signedTx.getSender() # verified

      let hashAhex = await client.eth_sendTransaction(unsignedTx)
      let hashBhex = await client.eth_sendRawTransaction(signedTxBytes)
      check hashAhex == hashBhex

    test "eth_call":
      var ec = TransactionArgs(
        `from`: w3Addr(signer).some,
        to: w3Addr(ks2).some,
        gas: w3Qty(100000'u).some,
        gasPrice: none(Quantity),
        value: some 100.u256
        )

      let res = await client.eth_call(ec, "latest")
      check res == hexToSeqByte("deadbeef")

    test "eth_estimateGas":
      var ec = TransactionArgs(
        `from`: w3Addr(signer).some,
        to: w3Addr(ks3).some,
        gas: w3Qty(42000'u).some,
        gasPrice: w3Qty(100'u).some,
        value: some 100.u256
        )

      let res = await client.eth_estimateGas(ec)
      check res == w3Qty(21000'u64)

    test "eth_getBlockByHash":
      let res = await client.eth_getBlockByHash(w3Hash env.blockHash, true)
      check res.isNil.not
      check res.hash == w3Hash env.blockHash
      let res2 = await client.eth_getBlockByHash(w3Hash env.txHash, true)
      check res2.isNil

    test "eth_getBlockByNumber":
      let res = await client.eth_getBlockByNumber("latest", true)
      check res.isNil.not
      check res.hash == w3Hash env.blockHash
      let res2 = await client.eth_getBlockByNumber($1, true)
      check res2.isNil

    test "eth_getTransactionByHash":
      let res = await client.eth_getTransactionByHash(w3Hash env.txHash)
      check res.isNil.not
      check res.blockNumber.get() == w3BlockNumber(1'u64)
      let res2 = await client.eth_getTransactionByHash(w3Hash env.blockHash)
      check res2.isNil

    test "eth_getTransactionByBlockHashAndIndex":
      let res = await client.eth_getTransactionByBlockHashAndIndex(w3Hash env.blockHash, w3Qty(0'u64))
      check res.isNil.not
      check res.blockNumber.get() == w3BlockNumber(1'u64)

      let res2 = await client.eth_getTransactionByBlockHashAndIndex(w3Hash env.blockHash, w3Qty(3'u64))
      check res2.isNil

      let res3 = await client.eth_getTransactionByBlockHashAndIndex(w3Hash env.txHash, w3Qty(3'u64))
      check res3.isNil

    test "eth_getTransactionByBlockNumberAndIndex":
      let res = await client.eth_getTransactionByBlockNumberAndIndex("latest", w3Qty(1'u64))
      check res.isNil.not
      check res.blockNumber.get() == w3BlockNumber(1'u64)

      let res2 = await client.eth_getTransactionByBlockNumberAndIndex("latest", w3Qty(3'u64))
      check res2.isNil

    test "eth_getTransactionReceipt":
      let res = await client.eth_getTransactionReceipt(w3Hash env.txHash)
      check res.isNil.not
      check res.blockNumber == w3BlockNumber(1'u64)

      let res2 = await client.eth_getTransactionReceipt(w3Hash env.blockHash)
      check res2.isNil

    test "eth_getUncleByBlockHashAndIndex":
      let res = await client.eth_getUncleByBlockHashAndIndex(w3Hash env.blockHash, w3Qty(0'u64))
      check res.isNil.not
      check res.number == w3BlockNumber(1'u64)

      let res2 = await client.eth_getUncleByBlockHashAndIndex(w3Hash env.blockHash, w3Qty(1'u64))
      check res2.isNil

      let res3 = await client.eth_getUncleByBlockHashAndIndex(w3Hash env.txHash, w3Qty(0'u64))
      check res3.isNil

    test "eth_getUncleByBlockNumberAndIndex":
      let res = await client.eth_getUncleByBlockNumberAndIndex("latest", w3Qty(0'u64))
      check res.isNil.not
      check res.number == w3BlockNumber(1'u64)

      let res2 = await client.eth_getUncleByBlockNumberAndIndex("latest", w3Qty(1'u64))
      check res2.isNil

    test "eth_getLogs by blockhash, no filters":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash
      let filterOptions = FilterOptions(
        blockHash: some(w3Hash testHash),
        topics: @[]
      )
      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 54

      var i = 0
      for l in logs:
        check:
          l.blockHash.isSome()
          l.blockHash.unsafeGet() == w3Hash testHash
          l.logIndex.unsafeGet() == w3Qty(i.uint64)
        inc i

    test "eth_getLogs by blockNumber, no filters":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash
      let fBlock = blockId(testHeader.blockNumber.truncate(uint64))
      let tBlock = blockId(testHeader.blockNumber.truncate(uint64))
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
          l.blockHash.unsafeGet() == w3Hash testHash
          l.logIndex.unsafeGet() == w3Qty(i.uint64)
        inc i

    test "eth_getLogs by blockhash, filter logs at specific positions":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash

      let topic = w3Hash("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      let topic1 = w3Hash("0x000000000000000000000000fdc183d01a793613736cd40a5a578f49add1772b")

      let filterOptions = FilterOptions(
        blockHash: some(w3Hash testHash),
        topics: @[
          TopicOrList(kind: slkList, list: @[topic]),
          TopicOrList(kind: slkNull),
          TopicOrList(kind: slkList, list: @[topic1])
        ]
      )

      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 1


    test "eth_getLogs by blockhash, filter logs at specific postions with or options":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash

      let topic = w3Hash("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      let topic1 = w3Hash("0xa64da754fccf55aa65a1f0128a648633fade3884b236e879ee9f64c78df5d5d7")

      let topic2 = w3Hash("0x000000000000000000000000e16c02eac87920033ac72fc55ee1df3151c75786")
      let topic3 = w3Hash("0x000000000000000000000000b626a5facc4de1c813f5293ec3be31979f1d1c78")



      let filterOptions = FilterOptions(
        blockHash: some(w3Hash testHash),
        topics: @[
          TopicOrList(kind: slkList, list: @[topic, topic1]),
          TopicOrList(kind: slkList, list: @[topic2, topic3])
        ]
      )

      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 2

    test "eth_getProof - Non existent account and storage slots":
      let blockData = await client.eth_getBlockByNumber("latest", true)

      block:
        # account doesn't exist
        let
          address = w3Addr("0x0000000000000000000000000000000000000004")
          proofResponse = await client.eth_getProof(address, @[], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isMissing()
          proofResponse.balance == 0.u256
          proofResponse.codeHash == zeroHash()
          proofResponse.nonce == w3Qty(0.uint64)
          proofResponse.storageHash == zeroHash()
          storageProof.len() == 0

      block:
        # account exists but requested slots don't exist
        let
          address = w3Addr("0x0000000000000000000000000000000000000001")
          slot1Key = 0.u256
          slot2Key = 1.u256
          proofResponse = await client.eth_getProof(address, @[slot1Key, slot2Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 2_000_000_000.u256
          proofResponse.codeHash == emptyCodeHash()
          proofResponse.nonce == w3Qty(1.uint64)
          proofResponse.storageHash == emptyStorageHash()
          storageProof.len() == 2
          storageProof[0].key == slot1Key
          storageProof[0].proof.len() == 0
          storageProof[0].value == 0.u256
          storageProof[1].key == slot2Key
          storageProof[1].proof.len() == 0
          storageProof[1].value == 0.u256

      block:
        # contract account with no storage slots
        let
          address = w3Addr("0x0000000000000000000000000000000000000003")
          slot1Key = 0.u256 # Doesn't exist
          proofResponse = await client.eth_getProof(address, @[slot1Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 0.u256
          proofResponse.codeHash == w3Hash("0x09044b55d7aba83cb8ac3d2c9c8d8bcadbfc33f06f1be65e8cc1e4ddab5f3074")
          proofResponse.nonce == w3Qty(0.uint64)
          proofResponse.storageHash == emptyStorageHash()
          storageProof.len() == 1
          storageProof[0].key == slot1Key
          storageProof[0].proof.len() == 0
          storageProof[0].value == 0.u256

    test "eth_getProof - Existing accounts and storage slots":
      let blockData = await client.eth_getBlockByNumber("latest", true)

      block:
        # contract account with storage slots
        let
          address = w3Addr("0x0000000000000000000000000000000000000002")
          slot1Key = 0.u256
          slot2Key = 1.u256
          slot3Key = 2.u256 # Doesn't exist
          proofResponse = await client.eth_getProof(address, @[slot1Key, slot2Key, slot3Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 1_000_000_000.u256
          proofResponse.codeHash == w3Hash("0x09044b55d7aba83cb8ac3d2c9c8d8bcadbfc33f06f1be65e8cc1e4ddab5f3074")
          proofResponse.nonce == w3Qty(2.uint64)
          proofResponse.storageHash == w3Hash("0x2ed06ec37dad4cd8c8fc1a1172d633a8973987fa6995b14a7c0a50c0e8d1a9c3")
          storageProof.len() == 3
          storageProof[0].key == slot1Key
          storageProof[0].proof.len() > 0
          storageProof[0].value == 1234.u256
          storageProof[1].key == slot2Key
          storageProof[1].proof.len() > 0
          storageProof[1].value == 2345.u256
          storageProof[2].key == slot3Key
          storageProof[2].proof.len() > 0
          storageProof[2].value == 0.u256
          verifySlotProof(proofResponse.storageHash, storageProof[0]).isValid()
          verifySlotProof(proofResponse.storageHash, storageProof[1]).isValid()
          verifySlotProof(proofResponse.storageHash, storageProof[2]).isMissing()

      block:
        # externally owned account
        let
          address = w3Addr("0x0000000000000000000000000000000000000001")
          proofResponse = await client.eth_getProof(address, @[], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 2_000_000_000.u256
          proofResponse.codeHash == emptyCodeHash()
          proofResponse.nonce == w3Qty(1.uint64)
          proofResponse.storageHash == emptyStorageHash()
          storageProof.len() == 0

    test "eth_getProof - Multiple blocks":
      let blockData = await client.eth_getBlockByNumber("latest", true)

      block:
        # block 0 - account doesn't exist yet
        let
          address = w3Addr("0x0000000000000000000000000000000000000002")
          slot1Key = 100.u256
          proofResponse = await client.eth_getProof(address, @[slot1Key], blockId(0'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).kind == InvalidProof
          proofResponse.balance == 0.u256
          proofResponse.codeHash == zeroHash()
          proofResponse.nonce == w3Qty(0.uint64)
          proofResponse.storageHash == zeroHash()
          storageProof.len() == 1
          verifySlotProof(proofResponse.storageHash, storageProof[0]).kind == InvalidProof

      block:
        # block 1 - account has balance, code and storage
        let
          address = w3Addr("0x0000000000000000000000000000000000000002")
          slot2Key = 1.u256
          proofResponse = await client.eth_getProof(address, @[slot2Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 1_000_000_000.u256
          proofResponse.codeHash == w3Hash("0x09044b55d7aba83cb8ac3d2c9c8d8bcadbfc33f06f1be65e8cc1e4ddab5f3074")
          proofResponse.nonce == w3Qty(2.uint64)
          proofResponse.storageHash == w3Hash("0x2ed06ec37dad4cd8c8fc1a1172d633a8973987fa6995b14a7c0a50c0e8d1a9c3")
          storageProof.len() == 1
          verifySlotProof(proofResponse.storageHash, storageProof[0]).isValid()

      test "eth_getBlockReceipts":
        let recs = await client.eth_getBlockReceipts(blockId("latest"))
        check recs.isSome
        if recs.isSome:
          let receipts = recs.get
          check receipts.len == 2
          check receipts[0].transactionIndex == 0.Quantity
          check receipts[1].transactionIndex == 1.Quantity

    rpcServer.stop()
    rpcServer.close()

when isMainModule:
  rpcMain()
