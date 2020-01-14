import
  json_rpc/rpcserver, stew/endians2,
  eth/[p2p, async_utils], eth/p2p/rlpx_protocols/waku_protocol

proc generateTraffic(node: EthereumNode, amount = 100) {.async.} =
  var topicNumber  = 0'u32
  let payload = @[byte 0]
  for i in 0..<amount:
    discard waku_protocol.postMessage(node, ttl = 10,
      topic = toBytesLE(i.uint32), payload = payload)
    await sleepAsync(1.milliseconds)

proc setupWakuSimRPC*(node: EthereumNode, rpcsrv: RpcServer) =

  rpcsrv.rpc("wakusim_generateTraffic") do(amount: int) -> bool:
    traceAsyncErrors node.generateTraffic(amount)
    return true

  # TODO: add random traffic generation
