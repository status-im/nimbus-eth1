import
  strformat, chronicles, json_rpc/[rpcclient, rpcserver],
  eth/common as eth_common, eth/keys, eth/p2p/rlpx_protocols/waku_protocol,
  ../nimbus/rpc/[hexstrings, rpc_types, waku],
  options as what # TODO: Huh?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

# TODO: move this to rpc folder? Or just directly to nim-web3 and import that?
const sigPath = &"{sourceDir}{DirSep}..{DirSep}tests{DirSep}rpcclient{DirSep}ethcallsigs.nim"
createRpcSigs(RpcHttpClient, sigPath)

let
  bob = newRpcHttpClient()
  alice = newRpcHttpClient()

waitFor bob.connect("localhost", Port(8546))
waitFor alice.connect("localhost", Port(8547))

let symKey = "0x0000000000000000000000000000000000000000000000000000000000000001"

let
  topic = "0x12345678".toTopic()
  symKeyID = waitFor alice.shh_addSymKey(symKey)
  options = WhisperFilterOptions(symKeyID: some(symKeyID),
                                 topics: some(@[topic]))
  filterID = waitFor alice.shh_newMessageFilter(options)

let
  symkeyID2 = waitFor bob.shh_addSymKey(symKey)
  message = WhisperPostMessage(symKeyID: some(symkeyID2),
                               ttl: 30,
                               topic: some(topic),
                               payload: "0x45879632".HexDataStr,
                               powTime: 1.0,
                               powTarget: 0.002)
discard waitFor bob.shh_post(message)

var messages: seq[WhisperFilterMessage]
while messages.len == 0:
  messages = waitFor alice.shh_getFilterMessages(filterID)
  waitFor sleepAsync(100.milliseconds)
debug "Received message", payload = messages[0].payload
