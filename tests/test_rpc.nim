import
  unittest, json, strformat, nimcrypto, rlp,
  json_rpc/[rpcserver, rpcclient],
  ../nimbus/rpc/[common, p2p, hexstrings],
  ../nimbus/constants,
  ../nimbus/nimbus/[vm_state, config],
  ../nimbus/db/[state_db, db_chain], eth_common, byteutils,
  eth_trie/[memDb, types],
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
    emptyRlpHash = keccak256.digest(rlp.encode("").toOpenArray)
    header = BlockHeader(stateRoot: emptyRlpHash)
  var
    chain = newBaseChainDB(newMemoryDb())
    state = newBaseVMState(header, chain)
  ethNode.chain = chain

  let
    balance = 100.u256
    address: EthAddress = hexToByteArray[20]("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
  state.mutateStateDB:
    db.setBalance(address, balance)

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
