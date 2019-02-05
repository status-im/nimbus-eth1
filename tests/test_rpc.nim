# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, json, strformat, options,
  nimcrypto, eth/[rlp, keys], eth/trie/db, eth/p2p as eth_p2p,
  json_rpc/[rpcserver, rpcclient],
  ../nimbus/rpc/[common, p2p, hexstrings, rpc_types],
  ../nimbus/constants,
  ../nimbus/[vm_state, config],
  ../nimbus/db/[state_db, db_chain, storage_types], eth/common as eth_common, byteutils,
  ../nimbus/p2p/chain,
  ../nimbus/genesis,
  ./rpcclient/test_hexstrings

# Perform checks for hex string validation
doHexStrTests()

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

## Generate client convenience marshalling wrappers from forward declarations
## For testing, ethcallsigs needs to be kept in sync with ../nimbus/rpc/[common, p2p]
const sigPath = &"{sourceDir}{DirSep}rpcclient{DirSep}ethcallsigs.nim"
createRpcSigs(RpcSocketClient, sigPath)

proc setupEthNode: EthereumNode =
  var
    conf = getConfiguration()
    keypair: KeyPair
  keypair.seckey = conf.net.nodekey
  keypair.pubkey = conf.net.nodekey.getPublicKey()

  var srvAddress: Address
  srvAddress.ip = parseIpAddress("0.0.0.0")
  srvAddress.tcpPort = Port(conf.net.bindPort)
  srvAddress.udpPort = Port(conf.net.discPort)
  result = newEthereumNode(keypair, srvAddress, conf.net.networkId,
                              nil, "nimbus 0.1.0")

proc toEthAddressStr(address: EthAddress): EthAddressStr =
  result = ("0x" & address.toHex).ethAddressStr

proc doTests =
  # TODO: Include other transports such as Http
  var ethNode = setupEthNode()
  let
    emptyRlpHash = keccak256.digest(rlp.encode(""))
    header = BlockHeader(stateRoot: emptyRlpHash)
  var
    chain = newBaseChainDB(newMemoryDb())
    state = newBaseVMState(header, chain)
  ethNode.chain = newChain(chain)

  let
    balance = 100.u256
    address: EthAddress = hexToByteArray[20]("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
    conf = getConfiguration()
  defaultGenesisBlockForNetwork(conf.net.networkId.toPublicNetwork()).commit(chain)
  state.mutateStateDB:
    db.setBalance(address, balance)
  doAssert(canonicalHeadHashKey().toOpenArray in state.chainDb.db)

  # Create Ethereum RPCs
  let RPC_PORT = 8545
  var
    rpcServer = newRpcSocketServer(["localhost:" & $RPC_PORT])
    client = newRpcSocketClient()
  setupCommonRpc(rpcServer)
  setupEthRpc(ethNode, chain, rpcServer)

  # Begin tests
  rpcServer.start()
  waitFor client.connect("localhost", Port(RPC_PORT))

  # TODO: add more tests here
  suite "Remote Procedure Calls":
    test "eth_call":
      let
        blockNum = state.blockheader.blockNumber
        callParams = EthCall(value: some(100.u256))
        r1 = waitFor client.eth_call(callParams, "0x" & blockNum.toHex)
      check r1 == "0x"
    test "eth_getBalance":
      let r2 = waitFor client.eth_getBalance(ZERO_ADDRESS.toEthAddressStr, "0x0")
      check r2 == 0

      let blockNum = state.blockheader.blockNumber
      let r3 = waitFor client.eth_getBalance(address.toEthAddressStr, "0x" & blockNum.toHex)
      check r3 == 0
    test "eth_estimateGas":
      let
        call = EthCall()
        blockNum = state.blockheader.blockNumber
        r4 = waitFor client.eth_estimateGas(call, "0x" & blockNum.toHex)
      check r4 == 21_000

  rpcServer.stop()
  rpcServer.close()

doTests()
