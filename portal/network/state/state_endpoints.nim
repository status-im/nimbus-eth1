# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  eth/rlp,
  eth/common/[hashes, accounts, addresses],
  ./state_network,
  ./state_utils

export results, state_network, hashes, addresses

logScope:
  topics = "portal_state"

proc getNextNodeHash(
    trieNode: TrieNode, nibbles: UnpackedNibbles, nibbleIdx: var int
): Opt[(Nibbles, Hash32)] =
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
        return Opt.none((Nibbles, Hash32))

      nibbleIdx += 1
      return Opt.some(
        (nibbles[0 ..< nibbleIdx].packNibbles(), Hash32.fromBytes(nextHashBytes))
      )

    # leaf or extension node
    let
      (_, isLeaf, prefix) = decodePrefix(trieNodeRlp.listElem(0))
      unpackedPrefix = prefix.unpackNibbles()

    if unpackedPrefix != nibbles[nibbleIdx ..< nibbleIdx + unpackedPrefix.len()]:
      # The nibbles don't match so we stop the search and don't increment
      # the nibble index to indicate how many nibbles were consumed
      return Opt.none((Nibbles, Hash32))

    nibbleIdx += prefix.unpackNibbles().len()
    if isLeaf:
      return Opt.none((Nibbles, Hash32))

    # extension node
    let nextHashBytes = trieNodeRlp.listElem(1).toBytes()
    if nextHashBytes.len() == 0:
      return Opt.none((Nibbles, Hash32))

    Opt.some((nibbles[0 ..< nibbleIdx].packNibbles(), Hash32.fromBytes(nextHashBytes)))
  except RlpError as e:
    raiseAssert(e.msg)

proc getAccountProof(
    n: StateNetwork,
    stateRoot: Hash32,
    address: Address,
    maybeBlockHash: Opt[Hash32], # required for poke
): Future[Result[(TrieProof, bool), string]] {.async: (raises: [CancelledError]).} =
  let nibbles = address.toPath().unpackNibbles()

  var
    nibblesIdx = 0
    key = AccountTrieNodeKey.init(Nibbles.empty(), stateRoot)
    proof = TrieProof.empty()

    # Construct the parent offer which is used to provide the data needed to
    # implement poke after the account trie node has been retrieved
    maybeParentOffer =
      if maybeBlockHash.isSome():
        Opt.some(AccountTrieNodeOffer.init(proof, maybeBlockHash.get()))
      else:
        Opt.none(AccountTrieNodeOffer)

  while nibblesIdx < nibbles.len():
    let
      accountTrieNode = (await n.getAccountTrieNode(key, maybeParentOffer)).valueOr:
        return err("Failed to get account trie node when building account proof")
      trieNode = accountTrieNode.node
      added = proof.add(trieNode)
    doAssert(added)

    if maybeParentOffer.isSome():
      let added = maybeParentOffer.get().proof.add(trieNode)
      doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = AccountTrieNodeKey.init(nextPath, nextNodeHash)

  doAssert(nibblesIdx <= nibbles.len())
  ok((proof, nibblesIdx == nibbles.len()))

proc getStorageProof(
    n: StateNetwork,
    storageRoot: Hash32,
    address: Address,
    slotKey: UInt256,
    maybeBlockHash: Opt[Hash32],
    maybeAccProof: Opt[TrieProof],
): Future[Result[(TrieProof, bool), string]] {.async: (raises: [CancelledError]).} =
  let nibbles = slotKey.toPath().unpackNibbles()

  var
    addressHash = keccak256(address.data)
    nibblesIdx = 0
    key = ContractTrieNodeKey.init(addressHash, Nibbles.empty(), storageRoot)
    proof = TrieProof.empty()

    # Construct the parent offer which is used to provide the data needed to
    # implement poke after the contract trie node has been retrieved
    maybeParentOffer =
      if maybeBlockHash.isSome():
        doAssert maybeAccProof.isSome()
        Opt.some(
          ContractTrieNodeOffer.init(proof, maybeAccProof.get(), maybeBlockHash.get())
        )
      else:
        Opt.none(ContractTrieNodeOffer)

  while nibblesIdx < nibbles.len():
    let
      contractTrieNode = (await n.getContractTrieNode(key, maybeParentOffer)).valueOr:
        return err("Failed to get contract trie node when building storage proof")
      trieNode = contractTrieNode.node
      added = proof.add(trieNode)
    doAssert(added)

    if maybeParentOffer.isSome():
      let added = maybeParentOffer.get().storageProof.add(trieNode)
      doAssert(added)

    let (nextPath, nextNodeHash) = trieNode.getNextNodeHash(nibbles, nibblesIdx).valueOr:
      break

    key = ContractTrieNodeKey.init(addressHash, nextPath, nextNodeHash)

  doAssert(nibblesIdx <= nibbles.len())
  ok((proof, nibblesIdx == nibbles.len()))

proc getAccount*(
    n: StateNetwork,
    stateRoot: Hash32,
    address: Address,
    maybeBlockHash = Opt.none(Hash32),
): Future[Opt[Account]] {.async: (raises: [CancelledError]).} =
  let (accountProof, exists) = (
    await n.getAccountProof(stateRoot, address, maybeBlockHash)
  ).valueOr:
    warn "Failed to get account proof", error = error
    return Opt.none(Account)

  if not exists:
    info "Account doesn't exist, returning default account"
    # return an empty account if the account doesn't exist
    return Opt.some(EMPTY_ACCOUNT)

  let account = accountProof.toAccount().valueOr:
    error "Failed to get account from accountProof"
    return Opt.none(Account)

  Opt.some(account)

proc getBalanceByStateRoot*(
    n: StateNetwork,
    stateRoot: Hash32,
    address: Address,
    maybeBlockHash = Opt.none(Hash32),
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let account = (await n.getAccount(stateRoot, address, maybeBlockHash)).valueOr:
    return Opt.none(UInt256)

  Opt.some(account.balance)

proc getTransactionCountByStateRoot*(
    n: StateNetwork,
    stateRoot: Hash32,
    address: Address,
    maybeBlockHash = Opt.none(Hash32),
): Future[Opt[AccountNonce]] {.async: (raises: [CancelledError]).} =
  let account = (await n.getAccount(stateRoot, address, maybeBlockHash)).valueOr:
    return Opt.none(AccountNonce)

  Opt.some(account.nonce)

proc getStorageAtByStateRoot*(
    n: StateNetwork,
    stateRoot: Hash32,
    address: Address,
    slotKey: UInt256,
    maybeBlockHash = Opt.none(Hash32),
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let (accountProof, exists) = (
    await n.getAccountProof(stateRoot, address, maybeBlockHash)
  ).valueOr:
    warn "Failed to get account proof", error = error
    return Opt.none(UInt256)

  let account =
    if exists:
      accountProof.toAccount().valueOr:
        error "Failed to get account from accountProof"
        return Opt.none(UInt256)
    else:
      info "Account doesn't exist, returning default account"
      # return an empty account if the account doesn't exist
      EMPTY_ACCOUNT

  if account.storageRoot == EMPTY_ROOT_HASH:
    info "Storage doesn't exist, returning default storage value"
    # return zero if the storage doesn't exist
    return Opt.some(0.u256)

  let (storageProof, slotExists) = (
    await n.getStorageProof(
      account.storageRoot, address, slotKey, maybeBlockHash, Opt.some(accountProof)
    )
  ).valueOr:
    warn "Failed to get storage proof", error = error
    return Opt.none(UInt256)

  if not slotExists:
    info "Slot doesn't exist, returning default storage value"
    # return zero if the slot doesn't exist
    return Opt.some(0.u256)

  let slotValue = storageProof.toSlot().valueOr:
    error "Failed to get slot from storageProof"
    return Opt.none(UInt256)

  Opt.some(slotValue)

proc getCodeByStateRoot*(
    n: StateNetwork,
    stateRoot: Hash32,
    address: Address,
    maybeBlockHash = Opt.none(Hash32),
): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
  let (accountProof, exists) = (
    await n.getAccountProof(stateRoot, address, maybeBlockHash)
  ).valueOr:
    warn "Failed to get account proof", error = error
    return Opt.none(seq[byte])

  let account =
    if exists:
      accountProof.toAccount().valueOr:
        error "Failed to get account from accountProof"
        return Opt.none(seq[byte])
    else:
      info "Account doesn't exist, returning default account"
      # return an empty account if the account doesn't exist
      EMPTY_ACCOUNT

  if account.codeHash == EMPTY_CODE_HASH:
    info "Code doesn't exist, returning default code value"
    # return empty bytecode if the code doesn't exist
    return Opt.some(Bytecode.empty().asSeq())

  let
    contractCodeKey = ContractCodeKey.init(keccak256(address.data), account.codeHash)
    maybeParentOffer =
      if maybeBlockHash.isSome():
        Opt.some(
          ContractCodeOffer.init(Bytecode.empty(), accountProof, maybeBlockHash.get())
        )
      else:
        Opt.none(ContractCodeOffer)
    contractCodeRetrieval = (await n.getContractCode(contractCodeKey, maybeParentOffer)).valueOr:
      warn "Failed to get contract code"
      return Opt.none(seq[byte])

  Opt.some(contractCodeRetrieval.code.asSeq())

type Proofs* = ref object
  account*: Account
  accountProof*: TrieProof
  slots*: seq[(UInt256, UInt256)]
  slotProofs*: seq[TrieProof]

proc getProofsByStateRoot*(
    n: StateNetwork,
    stateRoot: Hash32,
    address: Address,
    slotKeys: seq[UInt256],
    maybeBlockHash = Opt.none(Hash32),
): Future[Opt[Proofs]] {.async: (raises: [CancelledError]).} =
  let
    (accountProof, accountExists) = (
      await n.getAccountProof(stateRoot, address, maybeBlockHash)
    ).valueOr:
      warn "Failed to get account proof", error = error
      return Opt.none(Proofs)
    account =
      if accountExists:
        accountProof.toAccount().valueOr:
          error "Failed to get account from accountProof"
          return Opt.none(Proofs)
      else:
        EMPTY_ACCOUNT
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
        await n.getStorageProof(
          account.storageRoot, address, slotKey, maybeBlockHash, Opt.some(accountProof)
        )
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
    n: StateNetwork, blockNumOrHash: uint64 | Hash32, address: Address
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let header = (await n.getBlockHeaderByBlockNumOrHash(blockNumOrHash)).valueOr:
    warn "Failed to get block header by block number or hash", blockNumOrHash
    return Opt.none(UInt256)

  await n.getBalanceByStateRoot(
    header.stateRoot, address, Opt.some(header.computeRlpHash())
  )

# Used by: eth_getTransactionCount
proc getTransactionCount*(
    n: StateNetwork, blockNumOrHash: uint64 | Hash32, address: Address
): Future[Opt[AccountNonce]] {.async: (raises: [CancelledError]).} =
  let header = (await n.getBlockHeaderByBlockNumOrHash(blockNumOrHash)).valueOr:
    warn "Failed to get block header by block number or hash", blockNumOrHash
    return Opt.none(AccountNonce)

  await n.getTransactionCountByStateRoot(
    header.stateRoot, address, Opt.some(header.computeRlpHash())
  )

# Used by: eth_getStorageAt
proc getStorageAt*(
    n: StateNetwork, blockNumOrHash: uint64 | Hash32, address: Address, slotKey: UInt256
): Future[Opt[UInt256]] {.async: (raises: [CancelledError]).} =
  let header = (await n.getBlockHeaderByBlockNumOrHash(blockNumOrHash)).valueOr:
    warn "Failed to get block header by block number or hash", blockNumOrHash
    return Opt.none(UInt256)

  await n.getStorageAtByStateRoot(
    header.stateRoot, address, slotKey, Opt.some(header.computeRlpHash())
  )

# Used by: eth_getCode
proc getCode*(
    n: StateNetwork, blockNumOrHash: uint64 | Hash32, address: Address
): Future[Opt[seq[byte]]] {.async: (raises: [CancelledError]).} =
  let header = (await n.getBlockHeaderByBlockNumOrHash(blockNumOrHash)).valueOr:
    warn "Failed to get block header by block number or hash", blockNumOrHash
    return Opt.none(seq[byte])

  await n.getCodeByStateRoot(
    header.stateRoot, address, Opt.some(header.computeRlpHash())
  )

# Used by: eth_getProof
proc getProofs*(
    n: StateNetwork,
    blockNumOrHash: uint64 | Hash32,
    address: Address,
    slotKeys: seq[UInt256],
): Future[Opt[Proofs]] {.async: (raises: [CancelledError]).} =
  let header = (await n.getBlockHeaderByBlockNumOrHash(blockNumOrHash)).valueOr:
    warn "Failed to get block header by block number or hash", blockNumOrHash
    return Opt.none(Proofs)

  await n.getProofsByStateRoot(
    header.stateRoot, address, slotKeys, Opt.some(header.computeRlpHash())
  )
