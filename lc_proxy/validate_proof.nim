# light client proxy
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[sequtils, typetraits, options],
  stint,
  stew/results,
  eth/common/eth_types as etypes,
  eth/common/eth_types_rlp,
  eth/rlp,
  eth/trie/hexary,
  web3/ethtypes

export results

func toMDigest(arg: FixedBytes[32]): MDigest[256] =
  MDigest[256](data: distinctBase(arg))

proc isValidProof(
    branch: seq[seq[byte]],
    rootHash: KeccakHash,
    key, value: seq[byte]): bool =
  try:
    # TODO: Investigate if this handles proof of non-existence.
    # Probably not as bool is not expressive enough to say if proof is valid, but
    # key actually does not exists in MPT
    return isValidBranch(branch, rootHash, key, value)
  except RlpError:
    return false

proc isAccountProofValidInternal(
    stateRoot: FixedBytes[32],
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: CodeHash,
    accountStorageRootHash: StorageHash,
    mptNodes: seq[RlpEncodedBytes]
    ): Option[etypes.Account] =
  let
    mptNodesBytes = mptNodes.mapIt(distinctBase(it))
    keccakStateRootHash = toMDigest(stateRoot)
    acc = etypes.Account(
      nonce: distinctBase(accountNonce),
      balance: accountBalance,
      storageRoot: toMDigest(accountStorageRootHash),
      codeHash: toMDigest(accountCodeHash)
    )
    accountEncoded = rlp.encode(acc)
    accountKey = toSeq(keccakHash(distinctBase(accountAddress)).data)

  let validProof = isValidProof(
    mptNodesBytes,
    keccakStateRootHash,
    accountKey,
    accountEncoded
  )

  if validProof:
    return some(acc)
  else:
    return none(etypes.Account)

proc isAccountProofValid*(
    stateRoot: FixedBytes[32],
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: CodeHash,
    accountStorageRootHash: StorageHash,
    mptNodes: seq[RlpEncodedBytes]
    ): bool =

  let maybeAccount = isAccountProofValidInternal(
    stateRoot,
    accountAddress,
    accountBalance,
    accountNonce,
    accountCodeHash,
    accountStorageRootHash,
    mptNodes
  )

  return maybeAccount.isSome()

proc isStorageProofValid(
    account: etypes.Account,
    storageProof: StorageProof): bool =
  let
    storageMptNodes = storageProof.proof.mapIt(distinctBase(it))
    key = toSeq(keccakHash(toBytesBE(storageProof.key)).data)
    encodedValue = rlp.encode(storageProof.value)

  return isValidProof(storageMptNodes, account.storageRoot, key, encodedValue)

proc getStorageData*(
    stateRoot: FixedBytes[32],
    requestedSlot: UInt256,
    proof: ProofResponse): Result[UInt256, string] =

  let maybeAccount = isAccountProofValidInternal(
    stateRoot,
    proof.address,
    proof.balance,
    proof.nonce,
    proof.codeHash,
    proof.storageHash,
    proof.accountProof
  )

  if maybeAccount.isSome():
    let account = maybeAccount.unsafeGet()

    if account.storageRoot == etypes.EMPTY_ROOT_HASH:
      # valid account with empty storage, in that case getStorageAt
      # return 0 value
      return ok(u256(0))

    if len(proof.storageProof) != 1:
      return err("no storage proof for requested slot")

    let sproof = proof.storageProof[0]

    if len(sproof.proof) == 0:
      return err("empty mpt proof for account with not empty storage")

    if sproof.key != requestedSlot:
      return err("received proof for invalid slot")

    if sproof.value == UInt256.zero:
      # TODO: zero value means that storage is empty. We need to verify proof of
      # no existance. As we currenctly do not have that ability just, return zero
      # value
      return ok(sproof.value)

    if isStorageProofValid(account, sproof):
      return ok(sproof.value)
    else:
      return err("invalid storage proof")

  else:
    return err("invalid account proof")
