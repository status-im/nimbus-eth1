# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import 
  std/json,
  eth/common, chronos, json_rpc/rpcclient

# Specification of api https://github.com/ethereum/stateless-ethereum-specs/blob/master/portal-bridge-nodes.md#api
# TODO after nethermind plugin will be ready we can get few responses from those endpoints, to create mock client to test if we
# properly parse respones
type
  BridgeClient* = RpcClient

# bridge_waitNewCanonicalChain
proc waitNewCanonicalChain*(bridgeClient: BridgeClient): Future[void] {.async, raises: [Defect, CatchableError].} = discard

#bridge_getBlockChanges
proc getBlockChanges*(bridgeClient: BridgeClient, blockHash: Hash256): Future[AccessList] {.async, raises: [Defect, CatchableError].} = discard

#bridge_getItemWitness"
proc getItemWitness*(bridgeClient: BridgeClient, blockHash: Hash256, acctAddr: EthAddress, slotAddr: StorageKey):
  Future[seq[seq[byte]]] {.async, raises: [Defect, CatchableError].} = discard

#bridge_getNextItem
proc getNextItem*(bridgeClient: BridgeClient, blockHash: Hash256, acctAddr: EthAddress, slotAddr: StorageKey):
  Future[(EthAddress, StorageKey)] {.async, raises: [Defect, CatchableError].} = discard

proc close*(bridgeClient: BridgeClient): Future[void] {.async, raises: [Defect, CatchableError].} = 
  await bridgeClient.close()
