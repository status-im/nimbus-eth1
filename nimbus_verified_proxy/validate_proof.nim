# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, typetraits, options],
  stint,
  results,
  nimcrypto/hash,
  eth/common/eth_types as etypes,
  eth/common/eth_types_rlp,
  eth/rlp,
  eth/trie/[hexary, hexary_proof_verification],
  web3/eth_api_types

export results

type
  FixedBytes[N: static int] = primitives.FixedBytes[N]
  Address = primitives.Address

func toMDigest(arg: primitives.FixedBytes[32]): MDigest[256] =
  MDigest[256](data: distinctBase(arg))

func emptyAccount(): etypes.Account =
  return etypes.Account(
    nonce: uint64(0),
    balance: UInt256.zero,
    storageRoot: etypes.EMPTY_ROOT_HASH,
    codeHash: etypes.EMPTY_CODE_HASH,
  )

proc isValidProof(
    branch: seq[seq[byte]], rootHash: KeccakHash, key, value: seq[byte]
): bool =
  try:
    # TODO: Investigate if this handles proof of non-existence.
    # Probably not as bool is not expressive enough to say if proof is valid,
    # but key actually does not exists in MPT
    return isValidBranch(branch, rootHash, key, value)
  except RlpError:
    return false

proc getAccountFromProof*(
    stateRoot: FixedBytes[32],
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: CodeHash,
    accountStorageRootHash: StorageHash,
    mptNodes: seq[RlpEncodedBytes],
): Result[etypes.Account, string] =
  let
    mptNodesBytes = mptNodes.mapIt(distinctBase(it))
    keccakStateRootHash = Hash32(stateRoot)
    acc = etypes.Account(
      nonce: distinctBase(accountNonce),
      balance: accountBalance,
      storageRoot: Hash32(accountStorageRootHash),
      codeHash: Hash32(accountCodeHash),
    )
    accountEncoded = rlp.encode(acc)
    accountKey = toSeq(keccakHash(distinctBase(accountAddress)).data)

  let proofResult =
    verifyMptProof(mptNodesBytes, keccakStateRootHash, accountKey, accountEncoded)

  case proofResult.kind
  of MissingKey:
    return ok(emptyAccount())
  of ValidProof:
    return ok(acc)
  of InvalidProof:
    return err(proofResult.errorMsg)

proc getStorageData(
    account: etypes.Account, storageProof: StorageProof
): Result[UInt256, string] =
  let
    storageMptNodes = storageProof.proof.mapIt(distinctBase(it))
    key = toSeq(keccakHash(toBytesBE(storageProof.key)).data)
    encodedValue = rlp.encode(storageProof.value)
    proofResult =
      verifyMptProof(storageMptNodes, account.storageRoot, key, encodedValue)

  case proofResult.kind
  of MissingKey:
    return ok(UInt256.zero)
  of ValidProof:
    return ok(storageProof.value)
  of InvalidProof:
    return err(proofResult.errorMsg)

proc getStorageData*(
    stateRoot: FixedBytes[32], requestedSlot: UInt256, proof: ProofResponse
): Result[UInt256, string] =
  let account =
    ?getAccountFromProof(
      stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
      proof.storageHash, proof.accountProof,
    )

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

  return getStorageData(account, sproof)

func isValidCode*(account: etypes.Account, code: openArray[byte]): bool =
  return account.codeHash == keccakHash(code)
