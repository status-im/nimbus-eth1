# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, sugar],
  eth/common,
  ../../../network/state/[state_content, state_utils, state_gossip],
  ./world_state

type OffersBuilderRef* = ref object
  worldState: WorldStateRef
  blockHash: BlockHash
  accountTrieOffers: seq[AccountTrieOfferWithKey]
  contractTrieOffers: seq[ContractTrieOfferWithKey]
  contractCodeOffers: seq[ContractCodeOfferWithKey]

proc init*(
    T: type OffersBuilderRef, worldState: WorldStateRef, blockHash: BlockHash
): T =
  T(worldState: worldState, blockHash: blockHash)

proc toTrieProof(proof: seq[seq[byte]]): TrieProof =
  TrieProof.init(proof.map((node) => TrieNode.init(node)))

proc buildAccountTrieNodeOffer(
    builder: var OffersBuilderRef, address: EthAddress, proof: TrieProof
) =
  try:
    let
      path = removeLeafKeyEndNibbles(
        Nibbles.init(worldState.toAccountKey(address).data, isEven = true), proof[^1]
      )
      offerKey = AccountTrieNodeKey.init(path, keccakHash(proof[^1].asSeq()))
      offerValue = AccountTrieNodeOffer.init(proof, builder.blockHash)

    builder.accountTrieOffers.add(offerValue.withKey(offerKey))
  except RlpError as e:
    raiseAssert(e.msg) # Should never happen

proc buildContractTrieNodeOffer(
    builder: var OffersBuilderRef,
    address: EthAddress,
    slotHash: SlotKeyHash,
    storageProof: TrieProof,
    accountProof: TrieProof,
) =
  let
    path = Nibbles.init(slotHash.data, isEven = true)
    offerKey =
      ContractTrieNodeKey.init(address, path, keccakHash(storageProof[^1].asSeq()))
    offerValue =
      ContractTrieNodeOffer.init(storageProof, accountProof, builder.blockHash)

  builder.contractTrieOffers.add(offerValue.withKey(offerKey))

proc buildContractCodeOffer(
    builder: var OffersBuilderRef,
    address: EthAddress,
    code: seq[byte],
    accountProof: TrieProof,
) =
  let
    offerKey = ContractCodeKey.init(address, keccakHash(code))
    offerValue =
      ContractCodeOffer.init(Bytecode.init(code), accountProof, builder.blockHash)

  builder.contractCodeOffers.add(offerValue.withKey(offerKey))

proc buildBlockOffers*(builder: var OffersBuilderRef) =
  for address, proof in builder.worldState.updatedAccountProofs():
    let accountProof = toTrieProof(proof)
    builder.buildAccountTrieNodeOffer(address, accountProof)

    for slotHash, sProof in builder.worldState.updatedStorageProofs(address):
      let storageProof = toTrieProof(sProof)
      builder.buildContractTrieNodeOffer(address, slotHash, storageProof, accountProof)

    let code = builder.worldState.getUpdatedBytecode(address)
    if code.len() > 0:
      builder.buildContractCodeOffer(address, code, accountProof)

proc getAccountTrieOffers*(builder: OffersBuilderRef): seq[AccountTrieOfferWithKey] =
  builder.accountTrieOffers

proc getContractTrieOffers*(builder: OffersBuilderRef): seq[ContractTrieOfferWithKey] =
  builder.contractTrieOffers

proc getContractCodeOffers*(builder: OffersBuilderRef): seq[ContractCodeOfferWithKey] =
  builder.contractCodeOffers
