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
): Future[Result[(TrieProof, bool), string]] {.async: (raises: [CancelledError]).} =
  let nibbles = address.toPath().unpackNibbles()

  var
    nibblesIdx = 0
    key = AccountTrieNodeKey.init(Nibbles.empty(), stateRoot)
    proof = TrieProof.empty()

  while nibblesIdx < nibbles.len():
    let accountTrieNode = (await n.getAccountTrieNode(key)).valueOr:
      return err("Failed to get account trie node when building account proof")

    let
      trieNode = accountTrieNode.node
      added = proof.add(trieNode)
    doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = AccountTrieNodeKey.init(nextPath, nextNodeHash)

  doAssert(nibblesIdx <= nibbles.len())
  ok((proof, nibblesIdx == nibbles.len()))

proc getStorageProof(
    n: StateNetwork, storageRoot: KeccakHash, address: EthAddress, slotKey: UInt256
): Future[Result[(TrieProof, bool), string]] {.async: (raises: [CancelledError]).} =
  let nibbles = slotKey.toPath().unpackNibbles()

  var
    addressHash = keccakHash(address)
    nibblesIdx = 0
    key = ContractTrieNodeKey.init(addressHash, Nibbles.empty(), storageRoot)
    proof = TrieProof.empty()

  while nibblesIdx < nibbles.len():
    let contractTrieNode = (await n.getContractTrieNode(key)).valueOr:
      return err("Failed to get contract trie node when building account proof")

    let
      trieNode = contractTrieNode.node
      added = proof.add(trieNode)
    doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = ContractTrieNodeKey.init(addressHash, nextPath, nextNodeHash)

  doAssert(nibblesIdx <= nibbles.len())
  ok((proof, nibblesIdx == nibbles.len()))

proc getAccount(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress
): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
  let (accountProof, exists) = (await n.getAccountProof(stateRoot, address)).valueOr:
    warn "Failed to get account proof", error = error
    return Opt.none(Account)

  if not exists:
    info "Account doesn't exist, returning default account"
    # return an empty account if the account doesn't exist
    return Opt.some(newAccount())

  let account = accountProof.toAccount().valueOr:
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
  let account = (await n.getAccount(stateRoot, address)).valueOr:
    return Opt.none(UInt256)

  if account.storageRoot == EMPTY_ROOT_HASH:
    info "Storage doesn't exist, returning default storage value"
    # return zero if the storage doesn't exist
    return Opt.some(0.u256)

  let (storageProof, exists) = (
    await n.getStorageProof(account.storageRoot, address, slotKey)
  ).valueOr:
    warn "Failed to get storage proof", error = error
    return Opt.none(UInt256)

  if not exists:
    info "Slot doesn't exist, returning default storage value"
    # return zero if the slot doesn't exist
    return Opt.some(0.u256)

  let slotValue = storageProof.toSlot().valueOr:
    error "Failed to get slot from storageProof"
    return Opt.none(UInt256)

  Opt.some(slotValue)

proc getCodeByStateRoot*(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress
): Future[Opt[Bytecode]] {.async: (raises: [CancelledError]).} =
  let account = (await n.getAccount(stateRoot, address)).valueOr:
    return Opt.none(Bytecode)

  if account.codeHash == EMPTY_CODE_HASH:
    info "Code doesn't exist, returning default code value"
    # return empty bytecode if the code doesn't exist
    return Opt.some(Bytecode.empty())

  let
    contractCodeKey = ContractCodeKey.init(keccakHash(address), account.codeHash)
    contractCodeRetrieval = (await n.getContractCode(contractCodeKey)).valueOr:
      warn "Failed to get contract code"
      return Opt.none(Bytecode)

  Opt.some(contractCodeRetrieval.code)

type Proofs* = ref object
  account*: Account
  accountProof*: TrieProof
  slots*: seq[(UInt256, UInt256)]
  slotProofs*: seq[TrieProof]

proc getProofsByStateRoot*(
    n: StateNetwork, stateRoot: KeccakHash, address: EthAddress, slotKeys: seq[UInt256]
): Future[Opt[Proofs]] {.async: (raises: [CancelledError]).} =
  let
    (accountProof, accountExists) = (await n.getAccountProof(stateRoot, address)).valueOr:
      warn "Failed to get account proof", error = error
      return Opt.none(Proofs)
    account =
      if accountExists:
        accountProof.toAccount().valueOr:
          error "Failed to get account from accountProof"
          return Opt.none(Proofs)
      else:
        newAccount()
    storageExists = account.storageRoot != EMPTY_ROOT_HASH

  var
    slots = newSeqOfCap[(UInt256, UInt256)](slotKeys.len)
    slotProofs = newSeqOfCap[TrieProof](slotKeys.len)

  for slotKey in slotKeys:
    if not storageExists:
      slots.add((slotKey, 0.u256))
      slotProofs.add(TrieProof.empty())
      continue

    let
      (storageProof, slotExists) = (
        await n.getStorageProof(account.storageRoot, address, slotKey)
      ).valueOr:
        warn "Failed to get storage proof", error = error
        return Opt.none(Proofs)
      slotValue =
        if slotExists:
          storageProof.toSlot().valueOr:
            error "Failed to get slot from storageProof"
            return Opt.none(Proofs)
        else:
          0.u256
    slots.add((slotKey, slotValue))
    slotProofs.add(storageProof)

  return Opt.some(
    Proofs(
      account: account, accountProof: accountProof, slots: slots, slotProofs: slotProofs
    )
  )

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

# Used by: eth_getProof
proc getProofs*(
    n: StateNetwork, blockHash: BlockHash, address: EthAddress, slotKeys: seq[UInt256]
): Future[Opt[Proofs]] {.async: (raises: [CancelledError]).} =
  let stateRoot = (await n.getStateRootByBlockHash(blockHash)).valueOr:
    warn "Failed to get state root by block hash"
    return Opt.none(Proofs)

  await n.getProofsByStateRoot(stateRoot, address, slotKeys)
