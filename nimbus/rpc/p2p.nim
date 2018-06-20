# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import nimcrypto, eth-rpc/server, eth_p2p
import ../config

proc setupP2PRPC*(server: P2PServer, rpcsrv: RpcServer) =
  rpcsrv.rpc("net_version") do() -> int:
    let conf = getConfiguration()
    result = conf.net.networkId
