# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import 
  std/json,
  eth/common, chronos, json_rpc/[rpcclient], httputils

# Specification of api https://github.com/ethereum/stateless-ethereum-specs/blob/master/portal-bridge-nodes.md#api
# TODO after nethermind plugin will be ready we can get few responses from those endpoints, to create mock client to test if we
# properly parse respones
type
  BridgeClientRef* = ref object
    client*: RpcClient

proc init*(T: type BridgeClientRef, client: RpcClient): T = T(client: client)

proc newHttpBridgeClient*(remoteAddrress: string): Future[BridgeClientRef] {.async.}=
  var client = newRpcHttpClient()
  client.httpMethod(MethodPost)
  await client.connect(remoteAddrress)
  return BridgeClientRef.init(client)

# bridge_waitNewCanonicalChain
proc waitNewCanonicalChain*(bridgeClient: BridgeClientRef): Future[void] {.async, raises: [Defect, CatchableError].} = discard

#bridge_getBlockChanges
proc getBlockChanges*(bridgeClient: BridgeClientRef, blockHash: Hash256): Future[AccessList] {.async, raises: [Defect, CatchableError].} = discard

#bridge_getItemWitness"
proc getItemWitness*(bridgeClient: BridgeClientRef, blockHash: Hash256, acctAddr: EthAddress, slotAddr: StorageKey):
  Future[seq[seq[byte]]] {.async, raises: [Defect, CatchableError].} = discard

#bridge_getNextItem
proc getNextItem*(bridgeClient: BridgeClientRef, blockHash: Hash256, acctAddr: EthAddress, slotAddr: StorageKey):
  Future[(EthAddress, StorageKey)] {.async, raises: [Defect, CatchableError].} = discard

proc close*(bridgeClient: BridgeClientRef): Future[void] {.async, raises: [Defect, CatchableError].} = 
  await bridgeClient.client.close()