import
  unittest, json, strformat, nimcrypto, rlp, options,
  json_rpc/[rpcserver, rpcclient],
  ../nimbus/rpc/[common, p2p, hexstrings, rpc_types],
  ../nimbus/constants,
  ../nimbus/nimbus/[vm_state, config],
  ../nimbus/db/[state_db, db_chain, storage_types], eth_common, byteutils,
  ../nimbus/p2p/chain,
  ../nimbus/genesis,  
  eth_trie/db,
  eth_p2p, eth_keys
import rpcclient/test_hexstrings

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
  assert(canonicalHeadHashKey().toOpenArray in state.chainDb.db)

  # Create Ethereum RPCs
  var
    rpcServer = newRpcSocketServer(["localhost:8545"])
    client = newRpcSocketClient()
  setupCommonRpc(rpcServer)
  setupEthRpc(ethNode, chain, rpcServer)

  # Begin tests
  rpcServer.start()
  waitFor client.connect("localhost", Port(8545))

  suite "Remote Procedure Calls":
    # TODO: Currently returning 'block not found' when fetching header in p2p, so cannot perform tests
    test "eth_call":
      let
        blockNum = state.blockheader.blockNumber
        callParams = EthCall(value: some(100.u256))
      var r = waitFor client.eth_call(callParams, "0x" & blockNum.toHex)
      echo r
    test "eth_getBalance":
      expect ValueError:
        # check error is raised on null address
        var r = waitFor client.eth_getBalance(ZERO_ADDRESS.toEthAddressStr, "0x0")

      let blockNum = state.blockheader.blockNumber
      var r = waitFor client.eth_getBalance(address.toEthAddressStr, "0x" & blockNum.toHex)
      echo r

  rpcServer.stop()
  rpcServer.close()

doTests()
