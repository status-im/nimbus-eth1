# nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import json_rpc/rpcserver, ../network/beacon/beacon_network

export rpcserver

# Nimbus/fluffy specific RPC methods for the Portal beacon network.
proc installPortalNimbusBeaconApiHandlers*(rpcServer: RpcServer, n: BeaconNetwork) =
  rpcServer.rpc("portal_nimbus_beaconSetTrustedBlockRoot") do(blockRoot: string) -> bool:
    let root = Digest.fromHex(blockRoot)
    n.trustedBlockRoot = Opt.some(root)
    true
