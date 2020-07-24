# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, json, strformat, strutils, options, tables, os,
  nimcrypto, stew/byteutils,
  json_rpc/[rpcserver, rpcclient], eth/common as eth_common,
  eth/[rlp, keys], eth/trie/db, eth/p2p/rlpx_protocols/eth_protocol,
  ../nimbus/rpc/[common, p2p, hexstrings, rpc_types],
  ../nimbus/[constants, vm_state, config, genesis, utils, transaction],
  ../nimbus/db/[accounts_cache, db_chain, storage_types],
  ../nimbus/p2p/chain,
  ./rpcclient/test_hexstrings, ./test_helpers

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

proc doTests {.async.} =
  # TODO: Include other transports such as Http
  var ethNode = setupEthNode(eth)
  let
    emptyRlpHash = keccak256.digest(rlp.encode(""))
    header = BlockHeader(stateRoot: emptyRlpHash)
  var
    chain = newBaseChainDB(newMemoryDb())
    state = newBaseVMState(emptyRlpHash, header, chain)
  ethNode.chain = newChain(chain)

  let
    balance = 100.u256
    address: EthAddress = hexToByteArray[20]("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")

    signer: EthAddress = hexToByteArray[20]("0x0e69cde81b1aa07a45c32c6cd85d67229d36bb1b")
    ks2: EthAddress = hexToByteArray[20]("0xa3b2222afa5c987da6ef773fde8d01b9f23d481f")
    ks3: EthAddress = hexToByteArray[20]("0x597176e9a64aad0845d83afdaf698fbeff77703b")

    conf = getConfiguration()

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
  state.mutateStateDB:
    db.setBalance(address, balance)
  doAssert(canonicalHeadHashKey().toOpenArray in state.chainDb.db)

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
      # genesis block doesn't have any transaction
      # to generate meaningful prices
      check res.string == "0x0"

    test "eth_accounts":
      let res = await client.eth_accounts()
      check signer.ethAddressStr in res
      check ks2.ethAddressStr in res
      check ks3.ethAddressStr in res

    test "eth_blockNumber":
      let res = await client.eth_blockNumber()
      check res.string == "0x0"

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
        value: encodeQuantity(100'u).some,
        data: HexDataStr("0x").some,
        )

      let res = await client.eth_call(ec, "latest")

    #test "eth_estimateGas":
    #  let
    #    call = EthCall()
    #    blockNum = state.blockheader.blockNumber
    #    r4 = await client.eth_estimateGas(call, "0x" & blockNum.toHex)
    #  check r4 == 21_000

  rpcServer.stop()
  rpcServer.close()

waitFor doTests()
