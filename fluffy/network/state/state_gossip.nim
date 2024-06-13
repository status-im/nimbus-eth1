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

type ProofWithPath = tuple[path: Nibbles, proof: TrieProof]

type AccountTrieOfferWithKey* =
  tuple[key: AccountTrieNodeKey, offer: AccountTrieNodeOffer]

type ContractTrieOfferWithKey* =
  tuple[key: ContractTrieNodeKey, offer: ContractTrieNodeOffer]

func withPath(proof: TrieProof, path: Nibbles): ProofWithPath =
  (path: path, proof: proof)

func withKey*(
    offer: AccountTrieNodeOffer, key: AccountTrieNodeKey
): AccountTrieOfferWithKey =
  (key: key, offer: offer)

func withKey*(
    offer: ContractTrieNodeOffer, key: ContractTrieNodeKey
): ContractTrieOfferWithKey =
  (key: key, offer: offer)

func getParent(p: ProofWithPath): ProofWithPath =
  doAssert(p.path.len() > 0, "nibbles too short")
  doAssert(p.proof.len() > 1, "proof too short")

  let
    parentProof = TrieProof.init(p.proof[0 ..^ 2])
    parentEndNode = rlpFromBytes(parentProof[^1].asSeq())

  # the trie proof should have already been validated when receiving the offer content
  doAssert(parentEndNode.listLen() == 2 or parentEndNode.listLen() == 17)

  var unpackedNibbles = p.path.unpackNibbles()

  if parentEndNode.listLen() == 17:
    # branch node so only need to remove a single nibble
    return parentProof.withPath(unpackedNibbles.dropN(1).packNibbles())

  # leaf or extension node so we need to remove one or more nibbles
  let prefixNibbles = decodePrefix(parentEndNode.listElem(0))[2]

  parentProof.withPath(unpackedNibbles.dropN(prefixNibbles.len()).packNibbles())

func getParent*(offerWithKey: AccountTrieOfferWithKey): AccountTrieOfferWithKey =
  let
    (key, offer) = offerWithKey
    parent = offer.proof.withPath(key.path).getParent()
    parentKey =
      AccountTrieNodeKey.init(parent.path, keccakHash(parent.proof[^1].asSeq()))
    parentOffer = AccountTrieNodeOffer.init(parent.proof, offer.blockHash)

  parentOffer.withKey(parentKey)

func getParent*(offerWithKey: ContractTrieOfferWithKey): ContractTrieOfferWithKey =
  let
    (key, offer) = offerWithKey
    parent = offer.storageProof.withPath(key.path).getParent()
    parentKey = ContractTrieNodeKey.init(
      key.address, parent.path, keccakHash(parent.proof[^1].asSeq())
    )
    parentOffer =
      ContractTrieNodeOffer.init(parent.proof, offer.accountProof, offer.blockHash)

  parentOffer.withKey(parentKey)

proc gossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: AccountTrieNodeKey,
    offer: AccountTrieNodeOffer,
) {.async.} =
  let req1Peers = await p.neighborhoodGossip(
    srcNodeId, ContentKeysList.init(@[keyBytes]), @[offerBytes]
  )
  info "Offered content gossipped successfully with peers", keyBytes, peers = req1Peers

proc gossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: ContractTrieNodeKey,
    offer: ContractTrieNodeOffer,
) {.async.} =
  let req1Peers = await p.neighborhoodGossip(
    srcNodeId, ContentKeysList.init(@[keyBytes]), @[offerBytes]
  )
  info "Offered content gossipped successfully with peers", keyBytes, peers = req1Peers

proc gossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: ContractCodeKey,
    offer: ContractCodeOffer,
) {.async.} =
  let peers = await p.neighborhoodGossip(
    srcNodeId, ContentKeysList.init(@[keyBytes]), @[offerBytes]
  )
  info "Offered content gossipped successfully with peers", keyBytes, peers

# Currently only used for testing to gossip an entire account trie proof
# This may also be useful for the state network bridge
proc recursiveGossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: AccountTrieNodeKey,
    offer: AccountTrieNodeOffer,
) {.async.} =
  asyncSpawn gossipOffer(p, srcNodeId, keyBytes, offerBytes, key, offer)

  # root node, recursive gossip is finished
  if key.path.unpackNibbles().len() == 0:
    return

  # continue the recursive gossip by sharing the parent offer with peers
  let
    (parentKey, parentOffer) = offer.withKey(key).getParent()
    parentKeyBytes = parentKey.toContentKey().encode()

  asyncSpawn recursiveGossipOffer(
    p, srcNodeId, parentKeyBytes, parentOffer.encode(), parentKey, parentOffer
  )

# Currently only used for testing to gossip an entire contract trie proof
# This may also be useful for the state network bridge
proc recursiveGossipOffer*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    keyBytes: ByteList,
    offerBytes: seq[byte],
    key: ContractTrieNodeKey,
    offer: ContractTrieNodeOffer,
) {.async.} =
  asyncSpawn gossipOffer(p, srcNodeId, keyBytes, offerBytes, key, offer)

  # root node, recursive gossip is finished
  if key.path.unpackNibbles().len() == 0:
    return

  # continue the recursive gossip by sharing the parent offer with peers
  let
    (parentKey, parentOffer) = offer.withKey(key).getParent()
    parentKeyBytes = parentKey.toContentKey().encode()

  asyncSpawn recursiveGossipOffer(
    p, srcNodeId, parentKeyBytes, parentOffer.encode(), parentKey, parentOffer
  )
