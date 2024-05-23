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
  eth/common,
  ../wire/portal_protocol,
  ./state_content,
  ./state_utils

export results, state_content

logScope:
  topics = "portal_state"

func getParent(nibbles: Nibbles, proof: TrieProof): (Nibbles, TrieProof) =
  doAssert(nibbles.len() > 0, "nibbles too short")
  doAssert(proof.len() > 1, "proof too short")

  let
    parentProof = TrieProof.init(proof[0 ..^ 2])
    parentEndNode = rlpFromBytes(parentProof[^1].asSeq())

  # the trie proof should have already been validated when receiving the offer content
  doAssert(parentEndNode.listLen() == 2 or parentEndNode.listLen() == 17)

  var unpackedNibbles = nibbles.unpackNibbles()

  if parentEndNode.listLen() == 17:
    # branch node so only need to remove a single nibble
    unpackedNibbles.setLen(unpackedNibbles.len() - 1)
    return (unpackedNibbles.packNibbles(), parentProof)

  # leaf or extension node so we need to remove one or more nibbles
  let (_, isEven, prefixNibbles) = decodePrefix(parentEndNode.listElem(0))

  var removeCount = (prefixNibbles.len() - 1) * 2
  if not isEven:
    inc removeCount

  unpackedNibbles.setLen(unpackedNibbles.len() - removeCount)
  (unpackedNibbles.packNibbles(), parentProof)

func getParent*(
    key: AccountTrieNodeKey, offer: AccountTrieNodeOffer
): (AccountTrieNodeKey, AccountTrieNodeOffer) =
  let
    (parentNibbles, parentProof) = getParent(key.path, offer.proof)
    parentKey =
      AccountTrieNodeKey.init(parentNibbles, keccakHash(parentProof[^1].asSeq()))
    parentOffer = AccountTrieNodeOffer.init(parentProof, offer.blockHash)

  (parentKey, parentOffer)

func getParent*(
    key: ContractTrieNodeKey, offer: ContractTrieNodeOffer
): (ContractTrieNodeKey, ContractTrieNodeOffer) =
  let
    (parentNibbles, parentProof) = getParent(key.path, offer.storageProof)
    parentKey = ContractTrieNodeKey.init(
      key.address, parentNibbles, keccakHash(parentProof[^1].asSeq())
    )
    parentOffer =
      ContractTrieNodeOffer.init(parentProof, offer.accountProof, offer.blockHash)

  (parentKey, parentOffer)

proc gossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: AccountTrieNodeKey,
    offer: AccountTrieNodeOffer,
) {.async.} =
  asyncSpawn p.neighborhoodGossipDiscardPeers(
    srcNodeId, ContentKeysList.init(@[keyBytes]), @[offerBytes]
  )

  # root node, recursive gossip is finished
  if key.path.unpackNibbles().len() == 0:
    return

  let (parentKey, parentOffer) = getParent(key, offer)
  asyncSpawn p.neighborhoodGossipDiscardPeers(
    srcNodeId,
    ContentKeysList.init(@[parentKey.toContentKey().encode()]),
    @[parentOffer.encode()],
  )

proc gossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: ContractTrieNodeKey,
    offer: ContractTrieNodeOffer,
) {.async.} =
  asyncSpawn p.neighborhoodGossipDiscardPeers(
    srcNodeId, ContentKeysList.init(@[keyBytes]), @[offerBytes]
  )

  # root node, recursive gossip is finished
  if key.path.unpackNibbles().len() == 0:
    return

  let (parentKey, parentOffer) = getParent(key, offer)
  asyncSpawn p.neighborhoodGossipDiscardPeers(
    srcNodeId,
    ContentKeysList.init(@[parentKey.toContentKey().encode()]),
    @[parentOffer.encode()],
  )

proc gossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: ContractCodeKey,
    offer: ContractCodeOffer,
) {.async.} =
  asyncSpawn p.neighborhoodGossipDiscardPeers(
    srcNodeId, ContentKeysList.init(@[keyBytes]), @[offerBytes]
  )
