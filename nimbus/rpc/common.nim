# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import json_rpc/server, nimcrypto
import ../config

proc setupCommonRPC*(server: RpcServer) =
  server.rpc("web3_clientVersion") do() -> string:
    result = NimbusIdent

  server.rpc("web3_sha3") do(data: string) -> string:
    var rawdata = fromHex(data)
    result = "0x" & $keccak_256.digest(rawdata)
