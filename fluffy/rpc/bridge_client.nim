# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/json,
  stew/[byteutils, results],
  eth/common, chronos, json_rpc/rpcclient

# Specification of api https://github.com/ethereum/stateless-ethereum-specs/blob/master/portal-bridge-nodes.md#api
# TODO after nethermind plugin will be ready we can get few responses from those endpoints, to create mock client to test if we
# properly parse respones
type
  BridgeClient* = RpcClient

from json_rpc/rpcserver import expect

proc parseWitness*(node: JsonNode): Result[seq[seq[byte]], string] =
  try:
    node.kind.expect(JArray, "blockWitness")
    if (node.len > 0):
      var rs = newSeqOfCap[seq[byte]](node.len)
      for elem in node.elems:
        elem.kind.expect(JString, "BlockWitnessArgument")
        let hexStr = elem.getStr
        let parsedHex = hexToSeqByte(hexStr)
        rs.add(parsedHex)
      return ok(rs)
    else:
      return ok(newSeq[seq[byte]](0))
  except ValueError as error:
    return err(error.msg)

# bridge_waitNewCanonicalChain
proc waitNewCanonicalChain*(bridgeClient: BridgeClient): Future[void] {.async.} = discard

#bridge_getBlockChanges
proc getBlockChanges*(bridgeClient: BridgeClient, blockHash: Hash256): Future[AccessList] {.async.} = discard

#bridge_getItemWitness
proc getItemWitness*(bridgeClient: BridgeClient, blockHash: Hash256, acctAddr: EthAddress, slotAddr: StorageKey):
  Future[seq[seq[byte]]] {.async.} = discard

#bridge_getNextItem
proc getNextItem*(bridgeClient: BridgeClient, blockHash: Hash256, acctAddr: EthAddress, slotAddr: StorageKey):
  Future[(EthAddress, StorageKey)] {.async.} = discard

# bridge_getBlockWitness
# Returns a list of all RLP-encoded merkle trie values (including contract bytecode) accessed during block execution
proc getBlockWitness*(bridgeClient: BridgeClient, blockNumber: BlockNumber):
  Future[Result[seq[seq[byte]], string]] {.async.} =
  let result = await bridgeClient.call("bridge_getBlockWitnessblockNumber", %[%blockNumber])
  return parseWitness(result)

proc close*(bridgeClient: BridgeClient): Future[void] {.async.} =
  await bridgeClient.close()
