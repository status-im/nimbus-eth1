import
  unittest, json, strformat,
  json_rpc/[rpcserver, rpcclient],
  ../nimbus/rpc/common, ../nimbus/constants, ../nimbus/nimbus/account,
  eth_common

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

## Generate client convenience marshalling wrappers from forward declarations
## For testing, ethcallsigs needs to be kept in sync with ../nimbus/rpc/common
const sigPath = &"{sourceDir}{DirSep}rpcclient{DirSep}ethcallsigs.nim"
createRpcSigs(RpcSocketClient, sigPath)

# TODO: Include other transports such as Http
var srv = newRpcSocketServer(["localhost:8545"])
var client = newRpcSocketClient()

# Create Ethereum RPCs
setupCommonRpc(srv)

srv.start()
waitFor client.connect("localhost", Port(8545))

suite "Server/Client RPC":
  var acct = newAccount(balance = 100.u256)
  test "eth_getBalance":
    expect ValueError:
      # check error is raised on null address
      let
        blockNumStr = "1"
        address = ZERO_ADDRESS
      var r = waitFor client.eth_getBalance(address, blockNumStr)

srv.stop()
srv.close()
