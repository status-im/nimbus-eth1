import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver],
  eth/common as eth_common, eth/keys, eth/p2p/rlpx_protocols/waku_protocol,
  ../nimbus/rpc/[hexstrings, rpc_types, waku],
  options as what # TODO: Huh?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

# TODO: move this to rpc folder? Or just directly to nim-web3 and import that?
const sigEthPath = &"{sourceDir}{DirSep}..{DirSep}tests{DirSep}rpcclient{DirSep}ethcallsigs.nim"
createRpcSigs(RpcHttpClient, sigEthPath)
const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

let
  trafficNode = newRpcHttpClient()
  lightWakuNode = newRpcHttpClient()
  lightNode = newRpcHttpClient()

waitFor lightWakuNode.connect("localhost", Port(8546))
waitFor lightNode.connect("localhost", Port(8547))
waitFor trafficNode.connect("localhost", Port(8549))

let
  symKey = "0x0000000000000000000000000000000000000000000000000000000000000001"
  topic = "0x01000000".toTopic()
  symKeyID = waitFor lightWakuNode.shh_addSymKey(symKey)
  options = WhisperFilterOptions(symKeyID: some(symKeyID),
                                 topics: some(@[topic]))
  filterID = waitFor lightWakuNode.shh_newMessageFilter(options)

  symKeyID2 = waitFor lightNode.shh_addSymKey(symKey)
  options2 = WhisperFilterOptions(symKeyID: some(symKeyID2),
                                 topics: some(@[topic]))
  filterID2 = waitFor lightNode.shh_newMessageFilter(options2)

  symkeyID3 = waitFor trafficNode.shh_addSymKey(symKey)

var message = WhisperPostMessage(symKeyID: some(symkeyID3),
                                ttl: 30,
                                topic: some(topic),
                                payload: "0x45879632".HexDataStr,
                                powTime: 1.0,
                                powTarget: 0.002)
discard waitFor trafficNode.shh_post(message)

var messages: seq[WhisperFilterMessage]

# Check if the subscription for the topic works
while messages.len == 0:
  messages = waitFor lightWakuNode.shh_getFilterMessages(filterID)
  waitFor sleepAsync(1000.milliseconds)
info "Received test message", payload = messages[0].payload

# Generate test traffic on node
discard waitFor trafficNode.wakusim_generateTraffic(10_000)
