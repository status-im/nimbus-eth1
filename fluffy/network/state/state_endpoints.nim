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

      let nextHashBytes = trieNodeRlp.listElem(nextNibble.int).toBytes()
      if nextHashBytes.len() == 0:
        return Opt.none((Nibbles, NodeHash))

      nibbleIdx += 1
      return Opt.some(
        (nibbles[0 ..< nibbleIdx].packNibbles(), KeccakHash.fromBytes(nextHashBytes))
      )

    # leaf or extension node
    let
      (_, isLeaf, prefix) = decodePrefix(trieNodeRlp.listElem(0))
      unpackedPrefix = prefix.unpackNibbles()

    if unpackedPrefix != nibbles[nibbleIdx ..< nibbleIdx + unpackedPrefix.len()]:
      # The nibbles don't match so we stop the search and don't increment
      # the nibble index to indicate how many nibbles were consumed
      return Opt.none((Nibbles, NodeHash))

    nibbleIdx += prefix.unpackNibbles().len()
    if isLeaf:
      return Opt.none((Nibbles, NodeHash))

    # extension node
    let nextHashBytes = trieNodeRlp.listElem(1).toBytes()
    if nextHashBytes.len() == 0:
      return Opt.none((Nibbles, NodeHash))

    Opt.some(
      (nibbles[0 ..< nibbleIdx].packNibbles(), KeccakHash.fromBytes(nextHashBytes))
    )
  except RlpError as e:
    raiseAssert(e.msg)

proc getAccountProof(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress
): Future[Opt[TrieProof]] {.async: (raises: [CancelledError]).} =
  let nibbles = address.toPath().unpackNibbles()

  var
    nibblesIdx = 0
    key = AccountTrieNodeKey.init(Nibbles.empty(), stateRoot)
    proof = TrieProof.empty()

  while nibblesIdx < nibbles.len():
    let
      accountTrieNode = (await n.getAccountTrieNode(key)).valueOr:
        warn "Failed to get account trie node when building account proof"
        return Opt.none(TrieProof)
      trieNode = accountTrieNode.node

    let added = proof.add(trieNode)
    doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = AccountTrieNodeKey.init(nextPath, nextNodeHash)

  if nibblesIdx < nibbles.len():
    Opt.none(TrieProof)
  else:
    Opt.some(proof)

proc getStorageProof(
    n: StateNetwork, storageRoot: KeccakHash, address: EthAddress, storageKey: UInt256
): Future[Opt[TrieProof]] {.async: (raises: [CancelledError]).} =
  let nibbles = storageKey.toPath().unpackNibbles()

  var
    addressHash = keccakHash(address)
    nibblesIdx = 0
    key = ContractTrieNodeKey.init(addressHash, Nibbles.empty(), storageRoot)
    proof = TrieProof.empty()

  while nibblesIdx < nibbles.len():
    let
      contractTrieNode = (await n.getContractTrieNode(key)).valueOr:
        warn "Failed to get contract trie node when building account proof"
        return Opt.none(TrieProof)
      trieNode = contractTrieNode.node

    let added = proof.add(trieNode)
    doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = ContractTrieNodeKey.init(addressHash, nextPath, nextNodeHash)

  if nibblesIdx < nibbles.len():
    Opt.none(TrieProof)
  else:
    Opt.some(proof)

proc getAccount(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress
): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
  let
    accountProof = (await n.getAccountProof(stateRoot, address)).valueOr:
      warn "Failed to get account proof"
      return Opt.none(Account)
    account = accountProof.toAccount().valueOr:
      error "Failed to get account from accountProof"
      return Opt.none(Account)

  Opt.some(account)

proc getBalanceByStateRoot*(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let account = (await n.getAccount(stateRoot, address)).valueOr:
    return Opt.none(UInt256)

  Opt.some(account.balance)

proc getTransactionCountByStateRoot*(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress
): Future[Opt[AccountNonce]] {.async: (raises: [CancelledError]).} =
  let account = (await n.getAccount(stateRoot, address)).valueOr:
    return Opt.none(AccountNonce)

  Opt.some(account.nonce)

proc getStorageAtByStateRoot*(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress, slotKey: UInt256
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let
    account = (await n.getAccount(stateRoot, address)).valueOr:
      return Opt.none(UInt256)
    storageProof = (await n.getStorageProof(account.storageRoot, address, slotKey)).valueOr:
      warn "Failed to get storage proof"
      return Opt.none(UInt256)
    slotValue = storageProof.toSlot().valueOr:
      error "Failed to get slot from storageProof"
      return Opt.none(UInt256)

  Opt.some(slotValue)

proc getCodeByStateRoot*(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress
): Future[Opt[Bytecode]] {.async: (raises: [CancelledError]).} =
  let
    account = (await n.getAccount(stateRoot, address)).valueOr:
      return Opt.none(Bytecode)
    contractCodeKey = ContractCodeKey.init(keccakHash(address), account.codeHash)

  let contractCodeRetrieval = (await n.getContractCode(contractCodeKey)).valueOr:
    warn "Failed to get contract code"
    return Opt.none(Bytecode)

  Opt.some(contractCodeRetrieval.code)

# Used by: eth_getBalance,
proc getBalance*(
    n: StateNetwork, blockHash: BlockHash, address: EthAddress
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let stateRoot = (await n.getStateRootByBlockHash(blockHash)).valueOr:
    warn "Failed to get state root by block hash"
    return Opt.none(UInt256)

  await n.getBalanceByStateRoot(stateRoot, address)

# Used by: eth_getTransactionCount
proc getTransactionCount*(
    n: StateNetwork, blockHash: BlockHash, address: EthAddress
): Future[Opt[AccountNonce]] {.async: (raises: [CancelledError]).} =
  let stateRoot = (await n.getStateRootByBlockHash(blockHash)).valueOr:
    warn "Failed to get state root by block hash"
    return Opt.none(AccountNonce)

  await n.getTransactionCountByStateRoot(stateRoot, address)

# Used by: eth_getStorageAt
proc getStorageAt*(
    n: StateNetwork, blockHash: BlockHash, address: EthAddress, slotKey: UInt256
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let stateRoot = (await n.getStateRootByBlockHash(blockHash)).valueOr:
    warn "Failed to get state root by block hash"
    return Opt.none(UInt256)

  await n.getStorageAtByStateRoot(stateRoot, address, slotKey)

# Used by: eth_getCode
proc getCode*(
    n: StateNetwork, blockHash: BlockHash, address: EthAddress
): Future[Opt[Bytecode]] {.async: (raises: [CancelledError]).} =
  let stateRoot = (await n.getStateRootByBlockHash(blockHash)).valueOr:
    warn "Failed to get state root by block hash"
    return Opt.none(Bytecode)

  await n.getCodeByStateRoot(stateRoot, address)
