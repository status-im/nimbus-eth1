# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  strutils, tables,
  nimcrypto, eth/common as eth_common, stint, json_rpc/server,
  eth/p2p,
  ../config, hexstrings

proc setupCommonRPC*(node: EthereumNode, server: RpcServer) =
  server.rpc("web3_clientVersion") do() -> string:
    result = NimbusIdent

  server.rpc("web3_sha3") do(data: HexDataStr) -> string:
    var rawdata = nimcrypto.fromHex(data.string[2 .. ^1])
    result = "0x" & $keccak_256.digest(rawdata)

  server.rpc("net_version") do() -> string:
    let conf = getConfiguration()
    result = $conf.net.networkId

  server.rpc("net_listening") do() -> bool:
    let conf = getConfiguration()
    let numPeers = node.peerPool.connectedNodes.len
    result = numPeers < conf.net.maxPeers

  server.rpc("net_peerCount") do() -> HexQuantityStr:
    let peerCount = uint node.peerPool.connectedNodes.len
    result = encodeQuantity(peerCount)
