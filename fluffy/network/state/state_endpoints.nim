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
  eth/common/eth_types,
  ./state_network,
  ./state_utils

export results, state_network

logScope:
  topics = "portal_state"

  # AccountTrieNodeKey* = object
  #   path*: Nibbles
  #   nodeHash*: NodeHash

  # ContractTrieNodeKey* = object
  #   address*: Address
  #   path*: Nibbles
  #   nodeHash*: NodeHash

  # ContractCodeKey* = object
  #   address*: Address
  #   codeHash*: CodeHash

# proc getAccountTrieNode*(
#     n: StateNetwork, key: AccountTrieNodeKey
# ): Future[Opt[AccountTrieNodeRetrieval]] {.inline.} =
#   n.getContent(key, AccountTrieNodeRetrieval)

# proc getContractTrieNode*(
#     n: StateNetwork, key: ContractTrieNodeKey
# ): Future[Opt[ContractTrieNodeRetrieval]] {.inline.} =
#   n.getContent(key, ContractTrieNodeRetrieval)

# proc getContractCode*(
#     n: StateNetwork, key: ContractCodeKey
# ): Future[Opt[ContractCodeRetrieval]] {.inline.} =
#   n.getContent(key, ContractCodeRetrieval)

proc getAccountProof(
    n: StateNetwork, stateRoot: KeccakHash, address: Address
): Future[Opt[TrieProof]] {.async.} =
  # let
  #   rootNodeKey = AccountTrieNodeKey.init(Nibbles.empty(), stateRoot)
  #   nibbles = address.toPath().unpackedNibbles()

  # var
  #   nibblesIdx = 0
  #   currentNode = await n.getAccountTrieNode(rootNodeKey).valueOr:
  #     # log something here
  #     return Opt.none(TrieProof)

  # while nibblesIdx < nibbles.len():
  #   # decode node found
  #   let
  #     thisNodeRlp = rlpFromBytes(p.asSeq())
  #   # get the next hash by looking at the nibbles in the path

  #   currentNode = await n.getAccountTrieNode(rootNodeKey).valueOr:
  #     # log something here
  #     return Opt.none(TrieProof)

  discard

proc getStorageProof(
    n: StateNetwork, storageRoot: KeccakHash, storageKey: UInt256
): Future[Opt[TrieProof]] {.async.} =
  discard

proc getAccount(
    n: StateNetwork, blockHash: BlockHash, address: Address
): Future[Opt[Account]] {.async.} =
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
): Future[Opt[UInt256]] {.async.} =
  let account = (await n.getAccount(blockHash, address)).valueOr:
    return Opt.none(UInt256)

  Opt.some(account.balance)

# Used by: eth_getTransactionCount
proc getTransactionCount*(
    n: StateNetwork, blockHash: BlockHash, address: Address
): Future[Opt[AccountNonce]] {.async.} =
  let account = (await n.getAccount(blockHash, address)).valueOr:
    return Opt.none(AccountNonce)

  Opt.some(account.nonce)

# Used by: eth_getStorageAt
proc getStorageAt*(
    n: StateNetwork, blockHash: BlockHash, address: Address, slotKey: UInt256
): Future[Opt[UInt256]] {.async.} =
  let
    account = (await n.getAccount(blockHash, address)).valueOr:
      return Opt.none(UInt256)
    storageProof = (await n.getStorageProof(account.storageRoot, slotKey)).valueOr:
      warn "Failed to get storage proof"
      return Opt.none(UInt256)
    slotValue = storageProof.toSlot().valueOr:
      warn "Failed to get slot from storageProof"
      return Opt.none(UInt256)

  Opt.some(slotValue)

# Used by: eth_getCode
proc getCode*(
    n: StateNetwork, address: Address, blockHash: BlockHash
): Future[Opt[Bytecode]] {.async.} =
  let
    account = (await n.getAccount(blockHash, address)).valueOr:
      return Opt.none(Bytecode)
    contractCodeKey = ContractCodeKey.init(address, account.codeHash)

  # get the code hash from the account
  let contractCodeRetrieval = (await n.getContractCode(contractCodeKey)).valueOr:
    warn "Failed to get contract code"
    return Opt.none(Bytecode)

  Opt.some(contractCodeRetrieval.code)

# TODO: Implement getProof
# Used by: eth_getProof
# proc getProof*(
#     n: StateNetwork, address: EthAddress, storageKeys: openArray[UInt256], blockHash: BlockHash
# ): Future[Opt[seq[seq[byte]]]] {.async.} =

# perhaps combining the proofs can be done in the web3 api layer using the below types
# web3/eth_api_types
# RlpEncodedBytes* = distinct seq[byte]

# StorageProof* = object
#   key*: UInt256
#   value*: UInt256
#   proof*: seq[RlpEncodedBytes]

# ProofResponse* = object
#   address*: Address
#   accountProof*: seq[RlpEncodedBytes]
#   balance*: UInt256
#   codeHash*: CodeHash
#   nonce*: Quantity
#   storageHash*: StorageHash
#   storageProof*: seq[StorageProof]
