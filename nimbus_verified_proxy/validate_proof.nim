# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  stint,
  results,
  eth/common/[base_rlp, accounts_rlp, hashes_rlp],
  eth/trie/[hexary_proof_verification],
  web3/eth_api_types

export results, stint, hashes_rlp, accounts_rlp, eth_api_types

proc getAccountFromProof*(
    stateRoot: Hash32,
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: Hash32,
    accountStorageRoot: Hash32,
    mptNodes: seq[RlpEncodedBytes],
): Result[Account, string] =
  let
    mptNodesBytes = mptNodes.mapIt(distinctBase(it))
    acc = Account(
      nonce: distinctBase(accountNonce),
      balance: accountBalance,
      storageRoot: accountStorageRoot,
      codeHash: accountCodeHash,
    )
    accountEncoded = rlp.encode(acc)
    accountKey = toSeq(keccak256((accountAddress.data)).data)

  let proofResult = verifyMptProof(mptNodesBytes, stateRoot, accountKey, accountEncoded)

  case proofResult.kind
  of MissingKey:
    return ok(EMPTY_ACCOUNT)
  of ValidProof:
    return ok(acc)
  of InvalidProof:
    return err(proofResult.errorMsg)

proc getStorageData(
    account: Account, storageProof: StorageProof
): Result[UInt256, string] =
  let
    storageMptNodes = storageProof.proof.mapIt(distinctBase(it))
    key = toSeq(keccak256(toBytesBE(storageProof.key)).data)
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
    stateRoot: Hash32, requestedSlot: UInt256, proof: ProofResponse
): Result[UInt256, string] =
  let account =
    ?getAccountFromProof(
      stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
      proof.storageHash, proof.accountProof,
    )

  if account.storageRoot == EMPTY_ROOT_HASH:
    # valid account with empty storage, in that case getStorageAt
    # return 0 value
    return ok(u256(0))

  if len(proof.storageProof) != 1:
    return err("no storage proof for requested slot")

  let storageProof = proof.storageProof[0]

  if len(storageProof.proof) == 0:
    return err("empty mpt proof for account with not empty storage")

  if storageProof.key != requestedSlot:
    return err("received proof for invalid slot")

  getStorageData(account, storageProof)

func isValidCode*(account: Account, code: openArray[byte]): bool =
  account.codeHash == keccak256(code)
