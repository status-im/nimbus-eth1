# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles,
  std/[json, typetraits, sequtils],
  asynctest,
  web3/eth_api,
  stew/byteutils,
  json_rpc/[rpcserver, rpcclient],
  eth/[p2p, rlp, trie/hexary_proof_verification],
  eth/common/[transaction_utils, addresses],
  ../hive_integration/nodocker/engine/engine_client,
  ../nimbus/[constants, transaction, config, version],
  ../nimbus/db/[ledger, storage_types],
  ../nimbus/sync/protocol,
  ../nimbus/core/[tx_pool, chain, pow/difficulty, casper],
  ../nimbus/utils/utils,
  ../nimbus/[common, rpc],
  ../nimbus/rpc/rpc_types,
  ../nimbus/beacon/web3_eth_conv,
   ./test_helpers,
   ./macro_assembler,
   ./test_block_fixture

type
  Hash32 = common.Hash32

  TestEnv = object
    conf     : NimbusConf
    com      : CommonRef
    txPool   : TxPoolRef
    server   : RpcHttpServer
    client   : RpcHttpClient
    chain    : ForkedChainRef
    ctx      : EthContext
    node     : EthereumNode
    txHash   : Hash32
    blockHash: Hash32
    nonce    : uint64
    chainId  : ChainId

const
  zeroHash = hash32"0x0000000000000000000000000000000000000000000000000000000000000000"
  emptyCodeHash = hash32"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  emptyStorageHash = hash32"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"
  genesisFile = "tests/customgenesis/cancun123.json"
  contractCode = evmByteCode:
    Push4 "0xDEADBEEF"  # PUSH
    Push1 "0x00"        # MSTORE AT 0x00
    Mstore
    Push1 "0x04"        # RETURN LEN
    Push1 "0x1C"        # RETURN OFFSET at 28
    Return
  keyStore = "tests/keystore"
  signer = address"0x0e69cde81b1aa07a45c32c6cd85d67229d36bb1b"
  contractAddress = address"0xa3b2222afa5c987da6ef773fde8d01b9f23d481f"
  extraAddress = address"0x597176e9a64aad0845d83afdaf698fbeff77703b"
  regularAcc = address"0x0000000000000000000000000000000000000001"
  contractAccWithStorage = address"0x0000000000000000000000000000000000000002"
  contractAccNoStorage = address"0x0000000000000000000000000000000000000003"
  feeRecipient = address"0000000000000000000000000000000000000212"
  prevRandao = Bytes32 EMPTY_UNCLE_HASH # it can be any valid hash
  oneETH = 1.u256 * 1_000_000_000.u256 * 1_000_000_000.u256

proc verifyAccountProof(trustedStateRoot: Hash32, res: ProofResponse): MptProofVerificationResult =
  let
    key = toSeq(keccak256(res.address.data).data)
    value = rlp.encode(Account(
        nonce: res.nonce.uint64,
        balance: res.balance,
        storageRoot: res.storageHash,
        codeHash: res.codeHash))

  verifyMptProof(
    seq[seq[byte]](res.accountProof),
    trustedStateRoot,
    key,
    value)

proc verifySlotProof(trustedStorageRoot: Hash32, slot: StorageProof): MptProofVerificationResult =
  let
    key = toSeq(keccak256(toBytesBE(slot.key)).data)
    value = rlp.encode(slot.value)

  verifyMptProof(
    seq[seq[byte]](slot.proof),
    trustedStorageRoot,
    key,
    value)

proc persistFixtureBlock(chainDB: CoreDbTxRef) =
  let header = getBlockHeader4514995()
  # Manually inserting header to avoid any parent checks
  discard chainDB.put(genericHashKey(header.blockHash).toOpenArray, rlp.encode(header))
  chainDB.addBlockNumberToHashLookup(header.number, header.blockHash)
  chainDB.persistTransactions(header.number, header.txRoot, getBlockBody4514995().transactions)
  chainDB.persistReceipts(header.receiptsRoot, getReceipts4514995())

proc setupConfig(): NimbusConf =
  makeConfig(@[
    "--custom-network:" & genesisFile
  ])

proc setupCom(conf: NimbusConf): CommonRef =
  CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    nil,
    conf.networkId,
    conf.networkParams
  )

proc setupClient(port: Port): RpcHttpClient =
  let client = newRpcHttpClient()
  waitFor client.connect("127.0.0.1", port, false)
  return client

proc close(env: TestEnv) =
  waitFor env.client.close()
  waitFor env.server.closeWait()

func makeTx(
    env: var TestEnv,
    signerKey: PrivateKey,
    recipient: addresses.Address,
    amount: UInt256,
    gasPrice: GasInt,
    payload: openArray[byte] = []
): Transaction =
  const
    gasLimit = 70000.GasInt

  let tx = Transaction(
    txType: TxLegacy,
    chainId: env.chainId,
    nonce: AccountNonce(env.nonce),
    gasPrice: gasPrice,
    gasLimit: gasLimit,
    to: Opt.some(recipient),
    value: amount,
    payload: @payload,
  )

  inc env.nonce
  signTransaction(tx, signerKey, eip155 = true)

proc setupEnv(envFork: HardFork = MergeFork): TestEnv =
  doAssert(envFork >= MergeFork)

  let
    conf  = setupConfig()

  conf.networkParams.genesis.alloc[contractAddress] = GenesisAccount(code: contractCode)
  conf.networkParams.genesis.alloc[signer] = GenesisAccount(balance: oneETH)

  # Test data created for eth_getProof tests
  conf.networkParams.genesis.alloc[regularAcc] = GenesisAccount(
    balance: 2_000_000_000.u256,
    nonce: 1.uint64)

  conf.networkParams.genesis.alloc[contractAccWithStorage] = GenesisAccount(
    balance: 1_000_000_000.u256,
    nonce: 2.uint64,
    code: contractCode,
    storage: {
      0.u256: 1234.u256,
      1.u256: 2345.u256,
    }.toTable)

  conf.networkParams.genesis.alloc[contractAccNoStorage] = GenesisAccount(code: contractCode)

  if envFork >= Shanghai:
    conf.networkParams.config.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    conf.networkParams.config.cancunTime = Opt.some(0.EthTime)

  if envFork >= Prague:
    conf.networkParams.config.pragueTime = Opt.some(0.EthTime)

  let
    com   = setupCom(conf)
    chain = ForkedChainRef.init(com)
    txPool = TxPoolRef.new(chain)

  let
    server = newRpcHttpServerWithParams("127.0.0.1:0").valueOr:
      echo "Failed to create rpc server: ", error
      quit(QuitFailure)
    serverApi = newServerAPI(txPool)
    client = setupClient(server.localAddress[0].port)
    ctx    = newEthContext()
    node   = setupEthNode(conf, ctx, eth)

  ctx.am.loadKeystores(keyStore).isOkOr:
    debugEcho error
    quit(QuitFailure)

  let acc1 = ctx.am.getAccount(signer).tryGet()
  ctx.am.unlockAccount(signer, acc1.keystore["password"].getStr()).isOkOr:
    debugEcho error
    quit(QuitFailure)

  setupServerAPI(serverApi, server, ctx)
  setupCommonRpc(node, conf, server)
  server.start()

  TestEnv(
    conf   : conf,
    com    : com,
    txPool : txPool,
    server : server,
    client : client,
    chain  : chain,
    ctx    : ctx,
    node   : node,
    chainId: conf.networkParams.config.chainId,
  )

proc generateBlock(env: var TestEnv) =
  let
    com = env.com
    xp  = env.txPool
    ctx = env.ctx
    txFrame = com.db.baseTxFrame()
    acc = ctx.am.getAccount(signer).tryGet()
    tx1 = env.makeTx(acc.privateKey, zeroAddress, 1.u256, 30_000_000_000'u64)
    tx2 = env.makeTx(acc.privateKey, zeroAddress, 2.u256, 30_000_000_100'u64)
    chain = env.chain

  doAssert xp.addTx(tx1).isOk
  doAssert xp.addTx(tx2).isOk
  doAssert(xp.len == 2)

  # generate block
  com.pos.prevRandao = prevRandao
  com.pos.feeRecipient = feeRecipient
  com.pos.timestamp = EthTime.now()

  let bundle = xp.assembleBlock().valueOr:
    debugEcho error
    quit(QuitFailure)

  let blk = bundle.blk
  doAssert(blk.transactions.len == 2)

  # import block
  chain.importBlock(blk).isOkOr:
    debugEcho error
    quit(QuitFailure)

  xp.removeNewBlockTxs(blk)

  txFrame.persistFixtureBlock()

  env.txHash = tx1.rlpHash
  env.blockHash = blk.header.blockHash

createRpcSigsFromNim(RpcClient):
  proc web3_clientVersion(): string
  proc web3_sha3(data: seq[byte]): Hash32
  proc net_version(): string
  proc net_listening(): bool
  proc net_peerCount(): Quantity

proc rpcMain*() =
  suite "Remote Procedure Calls":
    var env = setupEnv()
    env.generateBlock()
    let
      client = env.client
      node = env.node
      com = env.com

    test "web3_clientVersion":
      let res = await client.web3_clientVersion()
      check res == ClientId

    test "web3_sha3":
      let data = @(NimbusName.toOpenArrayByte(0, NimbusName.len-1))
      let res = await client.web3_sha3(data)
      let hash = keccak256(data)
      check hash == res

    test "net_version":
      let res = await client.net_version()
      check res == $env.conf.networkId

    test "net_listening":
      let res = await client.net_listening()
      let listening = node.peerPool.connectedNodes.len < env.conf.maxPeers
      check res == listening

    test "net_peerCount":
      let res = await client.net_peerCount()
      let peerCount = node.peerPool.connectedNodes.len
      check res == w3Qty(peerCount)

    test "eth_chainId":
      let res = await client.eth_chainId()
      check res == w3Qty(distinctBase(com.chainId))

    test "eth_syncing":
      let res = await client.eth_syncing()
      if res.syncing == false:
        let syncing = node.peerPool.connectedNodes.len > 0
        check syncing == false
      else:
        check com.syncStart == res.syncObject.startingBlock.uint64
        check com.syncCurrent == res.syncObject.currentBlock.uint64
        check com.syncHighest == res.syncObject.highestBlock.uint64

    test "eth_gasPrice":
      let res = await client.eth_gasPrice()
      check res == w3Qty(30_000_000_050)  # Avg of `unsignedTx1` / `unsignedTx2`

    test "eth_accounts":
      let res = await client.eth_accounts()
      check signer in res
      check contractAddress in res
      check extraAddress in res

    test "eth_blockNumber":
      let res = await client.eth_blockNumber()
      check res == w3Qty(0x1'u64)

    test "eth_getBalance":
      let a = await client.eth_getBalance(signer, blockId(1'u64))
      check a == 998739999997899997'u256
      let b = await client.eth_getBalance(regularAcc, blockId(1'u64))
      check b == 2_000_000_000.u256
      let c = await client.eth_getBalance(contractAccWithStorage, blockId(1'u64))
      check c == 1_000_000_000.u256

    test "eth_getStorageAt":
      let res = await client.eth_getStorageAt(contractAccWithStorage, 1.u256, blockId(1'u64))
      check FixedBytes[32](2345.u256.toBytesBE) == res

    test "eth_getTransactionCount":
      let res = await client.eth_getTransactionCount(signer, blockId(1'u64))
      check res == w3Qty(2'u64)

    test "eth_getBlockTransactionCountByHash":
      let res = await client.eth_getBlockTransactionCountByHash(env.blockHash)
      check res == w3Qty(2'u64)

    test "eth_getBlockTransactionCountByNumber":
      let res = await client.eth_getBlockTransactionCountByNumber(blockId(1'u64))
      check res == w3Qty(2'u64)

    test "eth_getUncleCountByBlockHash":
      let res = await client.eth_getUncleCountByBlockHash(env.blockHash)
      check res == w3Qty(0'u64)

    test "eth_getUncleCountByBlockNumber":
      let res = await client.eth_getUncleCountByBlockNumber(blockId(0'u64))
      check res == w3Qty(0'u64)

    test "eth_getCode":
      let res = await client.eth_getCode(contractAddress, blockId(1'u64))
      check res.len == contractCode.len

    test "eth_sign":
      let msg = "hello world"
      let msgBytes = @(msg.toOpenArrayByte(0, msg.len-1))

      expect JsonRpcError:
        discard await client.eth_sign(contractAddress, msgBytes)

      let res = await client.eth_sign(signer, msgBytes)
      let sig = Signature.fromRaw(res).tryGet()

      # now let us try to verify signature
      let msgData  = "\x19Ethereum Signed Message:\n" & $msg.len & msg
      let msgDataBytes = @(msgData.toOpenArrayByte(0, msgData.len-1))
      let msgHash = await client.web3_sha3(msgDataBytes)
      let pubkey = recover(sig, SkMessage(msgHash.data)).tryGet()
      let recoveredAddr = pubkey.toCanonicalAddress()
      check recoveredAddr == signer # verified

    test "eth_signTransaction, eth_sendTransaction":
      let unsignedTx = TransactionArgs(
        `from`: Opt.some(signer),
        to: Opt.some(contractAddress),
        gas: Opt.some(w3Qty(100000'u)),
        gasPrice: Opt.none(Quantity),
        value: Opt.some(100.u256),
        nonce: Opt.some(2.Quantity)
        )

      let signedTxBytes = await client.eth_signTransaction(unsignedTx)
      let signedTx = rlp.decode(signedTxBytes, Transaction)
      check signer == signedTx.recoverSender().expect("valid signature") # verified

      let txHash = await client.eth_sendTransaction(unsignedTx)
      const expHash = hash32"0x929d48788096f26cfff70296b16c9974e6b1bf693c0121742e8527bb92b6d074"
      check txHash == expHash

    test "eth_sendRawTransaction":
      let unsignedTx = TransactionArgs(
        `from`: Opt.some(signer),
        to: Opt.some(contractAddress),
        gas: Opt.some(w3Qty(100001'u)),
        gasPrice: Opt.none(Quantity),
        value: Opt.some(100.u256),
        nonce: Opt.some(3.Quantity)
        )

      let signedTxBytes = await client.eth_signTransaction(unsignedTx)
      let signedTx = rlp.decode(signedTxBytes, Transaction)
      check signer == signedTx.recoverSender().expect("valid signature") # verified

      let txHash = await client.eth_sendRawTransaction(signedTxBytes)
      const expHash = hash32"0xeea79669dd904921d203fb720c7228f5c7854e5a768248f494f36fa68c83c191"
      check txHash == expHash

    test "eth_call":
      let ec = TransactionArgs(
        `from`: Opt.some(signer),
        to: Opt.some(contractAddress),
        gas: Opt.some(w3Qty(100000'u)),
        gasPrice: Opt.none(Quantity),
        value: Opt.some(100.u256)
        )

      let res = await client.eth_call(ec, "latest")
      check res == hexToSeqByte("deadbeef")

    test "eth_estimateGas":
      let ec = TransactionArgs(
        `from`: Opt.some(signer),
        to: Opt.some(extraAddress),
        gas: Opt.some(w3Qty(42000'u)),
        gasPrice: Opt.some(w3Qty(100'u)),
        value: Opt.some(100.u256)
        )

      let res = await client.eth_estimateGas(ec)
      check res == w3Qty(21000'u64)

    test "eth_getBlockByHash":
      let res = await client.eth_getBlockByHash(env.blockHash, true)
      check res.isNil.not
      check res.hash == env.blockHash
      let res2 = await client.eth_getBlockByHash(env.txHash, true)
      check res2.isNil

    test "eth_getBlockByNumber":
      let res = await client.eth_getBlockByNumber("latest", true)
      check res.isNil.not
      check res.hash == env.blockHash
      let res2 = await client.eth_getBlockByNumber($1, true)
      check res2.isNil

    test "eth_getTransactionByHash":
      let res = await client.eth_getTransactionByHash(env.txHash)
      check res.isNil.not
      check res.blockNumber.get() == w3Qty(1'u64)
      let res2 = await client.eth_getTransactionByHash(env.blockHash)
      check res2.isNil

    test "eth_getTransactionByBlockHashAndIndex":
      let res = await client.eth_getTransactionByBlockHashAndIndex(env.blockHash, w3Qty(0'u64))
      check res.isNil.not
      check res.blockNumber.get() == w3Qty(1'u64)

      let res2 = await client.eth_getTransactionByBlockHashAndIndex(env.blockHash, w3Qty(3'u64))
      check res2.isNil

      let res3 = await client.eth_getTransactionByBlockHashAndIndex(env.txHash, w3Qty(3'u64))
      check res3.isNil

    test "eth_getTransactionByBlockNumberAndIndex":
      let res = await client.eth_getTransactionByBlockNumberAndIndex("latest", w3Qty(1'u64))
      check res.isNil.not
      check res.blockNumber.get() == w3Qty(1'u64)

      let res2 = await client.eth_getTransactionByBlockNumberAndIndex("latest", w3Qty(3'u64))
      check res2.isNil

    test "eth_getBlockReceipts":
        let recs = await client.eth_getBlockReceipts(blockId(1'u64))
        check recs.isSome
        if recs.isSome:
          let receipts = recs.get
          check receipts.len == 2
          check receipts[0].transactionIndex == 0.Quantity
          check receipts[1].transactionIndex == 1.Quantity

    test "eth_getTransactionReceipt":
      let res = await client.eth_getTransactionReceipt(env.txHash)
      check res.isNil.not
      check res.blockNumber == w3Qty(1'u64)

      let res2 = await client.eth_getTransactionReceipt(env.blockHash)
      check res2.isNil

    test "eth_getUncleByBlockHashAndIndex":
      let res = await client.eth_getUncleByBlockHashAndIndex(env.blockHash, w3Qty(0'u64))
      check res.isNil

      let res2 = await client.eth_getUncleByBlockHashAndIndex(env.blockHash, w3Qty(1'u64))
      check res2.isNil

      let res3 = await client.eth_getUncleByBlockHashAndIndex(env.txHash, w3Qty(0'u64))
      check res3.isNil

    test "eth_getUncleByBlockNumberAndIndex":
      let res = await client.eth_getUncleByBlockNumberAndIndex("latest", w3Qty(0'u64))
      check res.isNil

      let res2 = await client.eth_getUncleByBlockNumberAndIndex("latest", w3Qty(1'u64))
      check res2.isNil

    test "eth_getLogs by blockhash, no filters":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash
      let filterOptions = FilterOptions(
        blockHash: Opt.some(testHash),
        topics: @[]
      )
      let logs = await client.eth_getLogs(filterOptions)

      check:
        len(logs) == 54

      var i = 0
      for l in logs:
        check:
          l.blockHash.isSome()
          l.blockHash.get() == testHash
          l.logIndex.get() == w3Qty(i.uint64)
        inc i

    test "eth_getLogs by blockhash, filter logs at specific positions":
      let testHeader = getBlockHeader4514995()
      let testHash = testHeader.blockHash

      let topic = bytes32"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
      let topic1 = bytes32"0x000000000000000000000000fdc183d01a793613736cd40a5a578f49add1772b"

      let filterOptions = FilterOptions(
        blockHash: Opt.some(testHash),
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

      let topic = bytes32"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
      let topic1 = bytes32"0xa64da754fccf55aa65a1f0128a648633fade3884b236e879ee9f64c78df5d5d7"

      let topic2 = bytes32"0x000000000000000000000000e16c02eac87920033ac72fc55ee1df3151c75786"
      let topic3 = bytes32"0x000000000000000000000000b626a5facc4de1c813f5293ec3be31979f1d1c78"



      let filterOptions = FilterOptions(
        blockHash: Opt.some(testHash),
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
          address = address"0x0000000000000000000000000000000000000004"
          proofResponse = await client.eth_getProof(address, @[], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isMissing()
          proofResponse.balance == 0.u256
          proofResponse.codeHash == zeroHash
          proofResponse.nonce == w3Qty(0.uint64)
          proofResponse.storageHash == zeroHash
          storageProof.len() == 0

      block:
        # account exists but requested slots don't exist
        let
          address = regularAcc
          slot1Key = 0.u256
          slot2Key = 1.u256
          proofResponse = await client.eth_getProof(address, @[slot1Key, slot2Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 2_000_000_000.u256
          proofResponse.codeHash == emptyCodeHash
          proofResponse.nonce == w3Qty(1.uint64)
          proofResponse.storageHash == emptyStorageHash
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
          address = contractAccNoStorage
          slot1Key = 0.u256 # Doesn't exist
          proofResponse = await client.eth_getProof(address, @[slot1Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 0.u256
          proofResponse.codeHash == hash32"0x09044b55d7aba83cb8ac3d2c9c8d8bcadbfc33f06f1be65e8cc1e4ddab5f3074"
          proofResponse.nonce == w3Qty(0.uint64)
          proofResponse.storageHash == emptyStorageHash
          storageProof.len() == 1
          storageProof[0].key == slot1Key
          storageProof[0].proof.len() == 0
          storageProof[0].value == 0.u256

    test "eth_getProof - Existing accounts and storage slots":
      let blockData = await client.eth_getBlockByNumber("latest", true)

      block:
        # contract account with storage slots
        let
          address = contractAccWithStorage
          slot1Key = 0.u256
          slot2Key = 1.u256
          slot3Key = 2.u256 # Doesn't exist
          proofResponse = await client.eth_getProof(address, @[slot1Key, slot2Key, slot3Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 1_000_000_000.u256
          proofResponse.codeHash == hash32"0x09044b55d7aba83cb8ac3d2c9c8d8bcadbfc33f06f1be65e8cc1e4ddab5f3074"
          proofResponse.nonce == w3Qty(2.uint64)
          proofResponse.storageHash == hash32"0x2ed06ec37dad4cd8c8fc1a1172d633a8973987fa6995b14a7c0a50c0e8d1a9c3"
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
          address = regularAcc
          proofResponse = await client.eth_getProof(address, @[], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 2_000_000_000.u256
          proofResponse.codeHash == emptyCodeHash
          proofResponse.nonce == w3Qty(1.uint64)
          proofResponse.storageHash == emptyStorageHash
          storageProof.len() == 0

    test "eth_getProof - Multiple blocks":
      let blockData = await client.eth_getBlockByNumber("latest", true)

      block:
        # block 1 - account has balance, code and storage
        let
          address = contractAccWithStorage
          slot2Key = 1.u256
          proofResponse = await client.eth_getProof(address, @[slot2Key], blockId(1'u64))
          storageProof = proofResponse.storageProof

        check:
          proofResponse.address == address
          verifyAccountProof(blockData.stateRoot, proofResponse).isValid()
          proofResponse.balance == 1_000_000_000.u256
          proofResponse.codeHash == hash32"0x09044b55d7aba83cb8ac3d2c9c8d8bcadbfc33f06f1be65e8cc1e4ddab5f3074"
          proofResponse.nonce == w3Qty(2.uint64)
          proofResponse.storageHash == hash32"0x2ed06ec37dad4cd8c8fc1a1172d633a8973987fa6995b14a7c0a50c0e8d1a9c3"
          storageProof.len() == 1
          verifySlotProof(proofResponse.storageHash, storageProof[0]).isValid()

    env.close()

when isMainModule:
  rpcMain()
