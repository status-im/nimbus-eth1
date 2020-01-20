import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys, eth/p2p/rlpx_protocols/waku_protocol,
  ../nimbus/rpc/[hexstrings, rpc_types, waku],
  options as what # TODO: Huh?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

let
  trafficNode = newRpcHttpClient()
  lightWakuNode = newRpcHttpClient()
  lightNode = newRpcHttpClient()

waitFor lightWakuNode.connect("localhost", Port(8545))
waitFor lightNode.connect("localhost", Port(8546))
waitFor trafficNode.connect("localhost", Port(8548))

proc generateTopics(amount = 100): seq[waku_protocol.Topic] =
  var topic: waku_protocol.Topic
  for i in 0..<amount:
    if randomBytes(topic) != 4:
      raise newException(ValueError, "Generation of random topic failed.")
    result.add(topic)

let
  symKey = "0x0000000000000000000000000000000000000000000000000000000000000001"
  topics = generateTopics()
  symKeyID = waitFor lightWakuNode.waku_addSymKey(symKey)
  options = WhisperFilterOptions(symKeyID: some(symKeyID),
                                 topics: some(topics))
  filterID = waitFor lightWakuNode.waku_newMessageFilter(options)

  symKeyID2 = waitFor lightNode.waku_addSymKey(symKey)
  options2 = WhisperFilterOptions(symKeyID: some(symKeyID2),
                                 topics: some(topics))
  filterID2 = waitFor lightNode.waku_newMessageFilter(options2)

  symkeyID3 = waitFor trafficNode.waku_addSymKey(symKey)

var message = WhisperPostMessage(symKeyID: some(symkeyID3),
                                ttl: 30,
                                topic: some(topics[0]),
                                payload: "0x45879632".HexDataStr,
                                powTime: 1.0,
                                powTarget: 0.002)
discard waitFor trafficNode.waku_post(message)

var messages: seq[WhisperFilterMessage]

# Check if the subscription for the topic works
while messages.len == 0:
  messages = waitFor lightWakuNode.waku_getFilterMessages(filterID)
  waitFor sleepAsync(1000.milliseconds)
info "Received test message", payload = messages[0].payload

# Generate test traffic on node
discard waitFor trafficNode.wakusim_generateRandomTraffic(10_000)
