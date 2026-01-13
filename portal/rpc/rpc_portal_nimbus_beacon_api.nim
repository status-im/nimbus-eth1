# nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import json_rpc/rpcserver, ./rpc_types, ../network/beacon/beacon_light_client

export rpcserver

# nimbus portal specific RPC methods for the Portal beacon network.
proc installPortalNimbusBeaconApiHandlers*(rpcServer: RpcServer, lc: LightClient) =
  rpcServer.rpc("portal_nimbus_beaconSetTrustedBlockRoot", EthJson) do(blockRoot: string) -> bool:
    let root = Digest.fromHex(blockRoot)
    await lc.resetToTrustedBlockRoot(root)
    true
