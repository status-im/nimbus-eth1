# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  results,
  chronos,
  chronicles,
  eth/common/eth_hash,
  eth/common,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../database/content_db,
  ../history/history_network,
  ../wire/[portal_protocol, portal_stream],
  ./state_content

export results

logScope:
  topics = "portal_state"

proc gossipOffer*(
    p: PortalProtocol,
    maybeSrcNodeId: Opt[NodeId],
    decodedKey: AccountTrieNodeKey,
    decodedValue: AccountTrieNodeOffer,
): Future[void] {.async.} =
  var
    nibbles = decodedKey.path.unpackNibbles()
    proof = decodedValue.proof

  # When nibbles is empty this means the root node was received. Recursive
  # gossiping is finished.
  if nibbles.len() == 0:
    return

  # TODO: Review this logic.
  # Removing a single nibble will not work for extension nodes with multiple prefix nibbles
  discard nibbles.pop()
  discard (distinctBase proof).pop()
  let
    updatedValue = AccountTrieNodeOffer(proof: proof, blockHash: decodedValue.blockHash)
    updatedNodeHash = keccakHash(distinctBase proof[^1])
    encodedValue = SSZ.encode(updatedValue)
    updatedKey =
      AccountTrieNodeKey(path: nibbles.packNibbles(), nodeHash: updatedNodeHash)
    encodedKey =
      ContentKey(accountTrieNodeKey: updatedKey, contentType: accountTrieNode).encode()

  await p.neighborhoodGossipDiscardPeers(
    maybeSrcNodeId, ContentKeysList.init(@[encodedKey]), @[encodedValue]
  )

proc gossipOffer*(
    p: PortalProtocol,
    maybeSrcNodeId: Opt[NodeId],
    decodedKey: ContractTrieNodeKey,
    decodedValue: ContractTrieNodeOffer,
): Future[void] {.async.} =
  # TODO: Recursive gossiping for contract trie nodes
  return

proc gossipOffer*(
    p: PortalProtocol,
    maybeSrcNodeId: Opt[NodeId],
    decodedKey: ContractCodeKey,
    decodedValue: ContractCodeOffer,
): Future[void] {.async.} =
  # TODO: Recursive gossiping for bytecode?
  return

# proc gossipContent*(
#     p: PortalProtocol,
#     maybeSrcNodeId: Opt[NodeId],
#     contentKey: ByteList,
#     decodedKey: ContentKey,
#     contentValue: seq[byte],
#     decodedValue: OfferContentValue,
# ): Future[void] {.async.} =
#   case decodedKey.contentType
#   of unused:
#     raiseAssert "Gossiping content with unused content type"
#   of accountTrieNode:
#     await recursiveGossipAccountTrieNode(
#       p, maybeSrcNodeId, decodedKey, decodedValue.accountTrieNode
#     )
#   of contractTrieNode:
#     await recursiveGossipContractTrieNode(
#       p, maybeSrcNodeId, decodedKey, decodedValue.contractTrieNode
#     )
#   of contractCode:
#     await p.neighborhoodGossipDiscardPeers(
#       maybeSrcNodeId, ContentKeysList.init(@[contentKey]), @[contentValue]
#     )
