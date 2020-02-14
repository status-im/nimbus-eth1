import
  os, strformat, chronicles, json_rpc/[rpcclient, rpcserver], nimcrypto/sysrand,
  eth/common as eth_common, eth/keys, eth/p2p/rlpx_protocols/waku_protocol,
  ../nimbus/rpc/[hexstrings, rpc_types, waku],
  options as what # TODO: Huh? Redefinition?

from os import DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

const sigWakuPath = &"{sourceDir}{DirSep}rpc{DirSep}wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigWakuPath)

const topicAmount = 100

let
  trafficNode = newRpcHttpClient()
  lightNode = newRpcHttpClient()
  lightNode2 = newRpcHttpClient()

waitFor lightNode.connect("localhost", Port(8545))
waitFor lightNode2.connect("localhost", Port(8546))
waitFor trafficNode.connect("localhost", Port(8548))

proc generateTopics(amount = topicAmount): seq[waku_protocol.Topic] =
  var topic: waku_protocol.Topic
  for i in 0..<amount:
    if randomBytes(topic) != 4:
      raise newException(ValueError, "Generation of random topic failed.")
    result.add(topic)

let
  symKey = "0x0000000000000000000000000000000000000000000000000000000000000001"
  topics = generateTopics()
  symKeyID = waitFor lightNode.waku_addSymKey(symKey)
  options = WhisperFilterOptions(symKeyID: some(symKeyID),
                                 topics: some(topics))
  filterID = waitFor lightNode.waku_newMessageFilter(options)

  symKeyID2 = waitFor lightNode2.waku_addSymKey(symKey)
  options2 = WhisperFilterOptions(symKeyID: some(symKeyID2),
                                  topics: some(topics))
  filterID2 = waitFor lightNode2.waku_newMessageFilter(options2)

  symkeyID3 = waitFor trafficNode.waku_addSymKey(symKey)

var message = WhisperPostMessage(symKeyID: some(symkeyID3),
                                ttl: 30,
                                topic: some(topics[0]),
                                payload: "0x45879632".HexDataStr,
                                powTime: 1.0,
                                powTarget: 0.002)

info "Posting envelopes on all subscribed topics"
for i in 0..<topicAmount:
  message.topic = some(topics[i])
  discard waitFor trafficNode.waku_post(message)

# Check if the subscription for the topics works

waitFor sleepAsync(1000.milliseconds) # This is a bit brittle

let
  messages = waitFor lightNode.waku_getFilterMessages(filterID)
  messages2 = waitFor lightNode2.waku_getFilterMessages(filterID2)

if messages.len != topicAmount or messages2.len != topicAmount:
  error "Light node did not receive envelopes on all subscribed topics",
    lightnode1=messages.len, lightnode2=messages2.len
  quit 1

info "Received envelopes on all subscribed topics"

# Generate test traffic on node
discard waitFor trafficNode.wakusim_generateRandomTraffic(10_000)
info "Started random traffic generation"
