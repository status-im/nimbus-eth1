# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  eth/common/eth_hash,
  eth/common/eth_types,
  ../../common/common_utils,
  ./state_network,
  ./state_utils

export results, state_network

logScope:
  topics = "portal_state"

proc getNextNodeHash(
    trieNode: TrieNode, nibbles: UnpackedNibbles, nibbleIdx: var int
): Opt[(Nibbles, NodeHash)] =
  # the trie node should have already been validated against the lookup hash
  # so we expect that no rlp errors should be possible
  try:
    doAssert(nibbles.len() > 0)
    doAssert(nibbleIdx < nibbles.len())

    let trieNodeRlp = rlpFromBytes(trieNode.asSeq())

    doAssert(not trieNodeRlp.isEmpty())
    doAssert(trieNodeRlp.listLen() == 2 or trieNodeRlp.listLen() == 17)

    if trieNodeRlp.listLen() == 17:
      let nextNibble = nibbles[nibbleIdx]
      doAssert(nextNibble < 16)

      let nextHashBytes = trieNodeRlp.listElem(nextNibble.int)
      doAssert(not nextHashBytes.isEmpty())

      nibbleIdx += 1
      return Opt.some(
        (
          nibbles[0 ..< nibbleIdx].packNibbles(),
          KeccakHash.fromBytes(nextHashBytes.toBytes()),
        )
      )

    # leaf or extension node
    let (_, isLeaf, prefix) = decodePrefix(trieNodeRlp.listElem(0))
    if isLeaf:
      return Opt.none((Nibbles, NodeHash))

    # extension node
    nibbleIdx += prefix.unpackNibbles().len()

    let nextHashBytes = trieNodeRlp.listElem(1)
    doAssert(not nextHashBytes.isEmpty())

    Opt.some(
      (
        nibbles[0 ..< nibbleIdx].packNibbles(),
        KeccakHash.fromBytes(nextHashBytes.toBytes()),
      )
    )
  except RlpError as e:
    raiseAssert(e.msg)

proc getAccountProof(
    n: StateNetwork, stateRoot: KeccakHash, address: Address
): Future[Opt[TrieProof]] {.async: (raises: [CancelledError]).} =
  let nibbles = address.toPath().unpackNibbles()

  var
    nibblesIdx = 0
    key = AccountTrieNodeKey.init(Nibbles.empty(), stateRoot)
    proof = TrieProof.empty()

  while nibblesIdx < nibbles.len():
    let
      accountTrieNode = (await n.getAccountTrieNode(key)).valueOr:
        # log something here
        return Opt.none(TrieProof)
      trieNode = accountTrieNode.node

    let added = proof.add(trieNode)
    doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = AccountTrieNodeKey.init(nextPath, nextNodeHash)

  Opt.some(proof)

proc getStorageProof(
    n: StateNetwork, storageRoot: KeccakHash, address: Address, storageKey: UInt256
): Future[Opt[TrieProof]] {.async: (raises: [CancelledError]).} =
  let nibbles = storageKey.toPath().unpackNibbles()

  var
    nibblesIdx = 0
    key = ContractTrieNodeKey.init(address, Nibbles.empty(), storageRoot)
    proof = TrieProof.empty()

  while nibblesIdx < nibbles.len():
    let
      contractTrieNode = (await n.getContractTrieNode(key)).valueOr:
        # log something here
        return Opt.none(TrieProof)
      trieNode = contractTrieNode.node

    let added = proof.add(trieNode)
    doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = ContractTrieNodeKey.init(address, nextPath, nextNodeHash)

  Opt.some(proof)

proc getAccount(
    n: StateNetwork, blockHash: BlockHash, address: Address
): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
  let
    stateRoot = (await n.getStateRootByBlockHash(blockHash)).valueOr:
      warn "Failed to get state root by block hash"
      return Opt.none(Account)
    accountProof = (await n.getAccountProof(stateRoot, address)).valueOr:
      warn "Failed to get account proof"
      return Opt.none(Account)
    account = accountProof.toAccount().valueOr:
      warn "Failed to get account from accountProof"
      return Opt.none(Account)

  Opt.some(account)

# Used by: eth_getBalance,
proc getBalance*(
    n: StateNetwork, blockHash: BlockHash, address: Address
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let account = (await n.getAccount(blockHash, address)).valueOr:
    return Opt.none(UInt256)

  Opt.some(account.balance)

# Used by: eth_getTransactionCount
proc getTransactionCount*(
    n: StateNetwork, blockHash: BlockHash, address: Address
): Future[Opt[AccountNonce]] {.async: (raises: [CancelledError]).} =
  let account = (await n.getAccount(blockHash, address)).valueOr:
    return Opt.none(AccountNonce)

  Opt.some(account.nonce)

# Used by: eth_getStorageAt
proc getStorageAt*(
    n: StateNetwork, blockHash: BlockHash, address: Address, slotKey: UInt256
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let
    account = (await n.getAccount(blockHash, address)).valueOr:
      return Opt.none(UInt256)
    storageProof = (await n.getStorageProof(account.storageRoot, address, slotKey)).valueOr:
      warn "Failed to get storage proof"
      return Opt.none(UInt256)
    slotValue = storageProof.toSlot().valueOr:
      warn "Failed to get slot from storageProof"
      return Opt.none(UInt256)

  Opt.some(slotValue)

# Used by: eth_getCode
proc getCode*(
    n: StateNetwork, blockHash: BlockHash, address: Address
): Future[Opt[Bytecode]] {.async: (raises: [CancelledError]).} =
  let
    account = (await n.getAccount(blockHash, address)).valueOr:
      return Opt.none(Bytecode)
    contractCodeKey = ContractCodeKey.init(address, account.codeHash)

  let contractCodeRetrieval = (await n.getContractCode(contractCodeKey)).valueOr:
    warn "Failed to get contract code"
    return Opt.none(Bytecode)

  Opt.some(contractCodeRetrieval.code)
