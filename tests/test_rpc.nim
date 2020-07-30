# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, json, strformat, strutils, options, tables, os,
  nimcrypto, stew/byteutils, times,
  json_rpc/[rpcserver, rpcclient], eth/common as eth_common,
  eth/[rlp, keys], eth/trie/db, eth/p2p/rlpx_protocols/eth_protocol,
  ../nimbus/rpc/[common, p2p, hexstrings, rpc_types, rpc_utils],
  ../nimbus/[constants, vm_state, config, genesis, utils, transaction],
  ../nimbus/db/[accounts_cache, db_chain, storage_types, state_db],
  ../nimbus/p2p/[chain, executor], ../nimbus/utils/difficulty,
  ./rpcclient/test_hexstrings, ./test_helpers, ./macro_assembler

from eth/p2p/rlpx_protocols/whisper_protocol import SymKey

# Perform checks for hex string validation
#doHexStrTests()

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

## Generate client convenience marshalling wrappers from forward declarations
## For testing, ethcallsigs needs to be kept in sync with ../nimbus/rpc/[common, p2p]
const sigPath = &"{sourceDir}{DirSep}rpcclient{DirSep}ethcallsigs.nim"
createRpcSigs(RpcSocketClient, sigPath)

type
  TestEnv = object
    txHash: Hash256
    blockHash: HAsh256

proc setupEnv(chain: BaseChainDB, signer, ks2: EthAddress, conf: NimbusConfiguration): TestEnv =
  var
    parent = chain.getCanonicalHead()
    ac = newAccountStateDB(chain.db, parent.stateRoot, chain.pruneTrie)
    acc = conf.getAccount(signer).tryGet()
    blockNumber = 1.toBlockNumber
    parentHash = parent.blockHash
    fork = chain.config.toFork(blockNumber)

  const code = evmByteCode:
    PUSH4 "0xDEADBEEF"  # PUSH
    PUSH1 "0x00"        # MSTORE AT 0x00
    MSTORE
    PUSH1 "0x04"        # RETURN LEN
    PUSH1 "0x1C"        # RETURN OFFSET at 28
    RETURN

  ac.setCode(ks2, code)
  ac.addBalance(signer, 9_000_000_000.u256)
  var vmState = newBaseVMState(ac.rootHash, BlockHeader(parentHash: parentHash), chain)

  let
    unsignedTx1 = UnsignedTx(
      nonce   : 0,
      gasPrice: 1_100,
      gasLimit: 70_000,
      value   : 1.u256,
      contractCreation: false
    )
    unsignedTx2 = UnsignedTx(
      nonce   : 0,
      gasPrice: 1_200,
      gasLimit: 70_000,
      value   : 2.u256,
      contractCreation: false
    )
    signedTx1 = signTransaction(unsignedTx1, chain, acc.privateKey)
    signedTx2 = signTransaction(unsignedTx2, chain, acc.privateKey)
    txs = [signedTx1, signedTx2]
    txRoot = chain.persistTransactions(blockNumber, txs)

  vmState.receipts = newSeq[Receipt](txs.len)
  vmState.cumulativeGasUsed = 0
  for txIndex, tx in txs:
    let sender = tx.getSender()
    discard processTransaction(tx, sender, vmState, fork)
    vmState.receipts[txIndex] = makeReceipt(vmState, fork)

  let
    receiptRoot = chain.persistReceipts(vmState.receipts)
    date        = initDateTime(30, mMar, 2017, 00, 00, 00, 00, utc())
    timeStamp   = date.toTime
    difficulty  = calcDifficulty(chain.config, timeStamp, parent)

  var header = BlockHeader(
    parentHash  : parentHash,
    #coinbase*:      EthAddress
    stateRoot   : vmState.accountDb.rootHash,
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
  header.ommersHash = chain.persistUncles(uncles)

  discard chain.persistHeaderToDb(header)
  result = TestEnv(
    txHash: signedTx1.rlpHash,
    blockHash: header.hash
    )


proc doTests {.async.} =
  # TODO: Include other transports such as Http
  var
    ethNode = setupEthNode(eth)
    chain = newBaseChainDB(newMemoryDb())

  let
    signer: EthAddress = hexToByteArray[20]("0x0e69cde81b1aa07a45c32c6cd85d67229d36bb1b")
    ks2: EthAddress = hexToByteArray[20]("0xa3b2222afa5c987da6ef773fde8d01b9f23d481f")
    ks3: EthAddress = hexToByteArray[20]("0x597176e9a64aad0845d83afdaf698fbeff77703b")
    conf = getConfiguration()

  ethNode.chain = newChain(chain)
  conf.keyStore = "tests" / "keystore"
  let res = conf.loadKeystoreFiles()
  if res.isErr:
    debugEcho res.error
  doAssert(res.isOk)

  let acc1 = conf.getAccount(signer).tryGet()
  let unlock = conf.unlockAccount(signer, acc1.keystore["password"].getStr())
  if unlock.isErr:
    debugEcho unlock.error
  doAssert(unlock.isOk)

  defaultGenesisBlockForNetwork(conf.net.networkId.toPublicNetwork()).commit(chain)
  doAssert(canonicalHeadHashKey().toOpenArray in chain.db)
  let env = setupEnv(chain, signer, ks2, conf)

  # Create Ethereum RPCs
  let RPC_PORT = 8545
  var
    rpcServer = newRpcSocketServer(["localhost:" & $RPC_PORT])
    client = newRpcSocketClient()
  setupCommonRpc(ethNode, rpcServer)
  setupEthRpc(ethNode, chain, rpcServer)

  # Begin tests
  rpcServer.start()
  await client.connect("localhost", Port(RPC_PORT))

  # TODO: add more tests here
  suite "Remote Procedure Calls":
    test "web3_clientVersion":
      let res = await client.web3_clientVersion()
      check res == NimbusIdent

    test "web3_sha3":
      expect ValueError:
        discard await client.web3_sha3(NimbusName.HexDataStr)

      let data = "0x" & byteutils.toHex(NimbusName.toOpenArrayByte(0, NimbusName.len-1))
      let res = await client.web3_sha3(data.hexDataStr)
      let rawdata = nimcrypto.fromHex(data[2 .. ^1])
      let hash = "0x" & $keccak_256.digest(rawdata)
      check hash == res

    test "net_version":
      let res = await client.net_version()
      check res == $conf.net.networkId

    test "net_listening":
      let res = await client.net_listening()
      let listening = ethNode.peerPool.connectedNodes.len < conf.net.maxPeers
      check res == listening

    test "net_peerCount":
      let res = await client.net_peerCount()
      let peerCount = ethNode.peerPool.connectedNodes.len
      check isValidHexQuantity res.string
      check res == encodeQuantity(peerCount.uint)

    test "eth_protocolVersion":
      let res = await client.eth_protocolVersion()
      check res == $eth_protocol.protocolVersion

    test "eth_syncing":
      let res = await client.eth_syncing()
      if res.kind == JBool:
        let syncing = ethNode.peerPool.connectedNodes.len > 0
        check res.getBool() == syncing
      else:
        check res.kind == JObject
        check chain.startingBlock == UInt256.fromHex(res["startingBlock"].getStr())
        check chain.currentBlock == UInt256.fromHex(res["currentBlock"].getStr())
        check chain.highestBlock == UInt256.fromHex(res["highestBlock"].getStr())

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
      let res = await client.eth_getStorageAt(ethAddressStr("0xfff33a3bd36abdbd412707b8e310d6011454a7ae"), hexQuantityStr "0x0", "0x0")
      check hexDataStr(0.u256).string == hexDataStr(res).string

    test "eth_getTransactionCount":
      let res = await client.eth_getTransactionCount(ethAddressStr("0xfff7ac99c8e4feb60c9750054bdc14ce1857f181"), "0x0")
      check res.string == "0x0"

    test "eth_getBlockTransactionCountByHash":
      let hash = chain.getBlockHash(0.toBlockNumber)
      let res = await client.eth_getBlockTransactionCountByHash(hash)
      check res.string == "0x0"

    test "eth_getBlockTransactionCountByNumber":
      let res = await client.eth_getBlockTransactionCountByNumber("0x0")
      check res.string == "0x0"

    test "eth_getUncleCountByBlockHash":
      let hash = chain.getBlockHash(0.toBlockNumber)
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

  rpcServer.stop()
  rpcServer.close()

waitFor doTests()
