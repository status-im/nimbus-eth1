# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  stint,
  eth/common,
  eth/rlp,
  eth/trie/hexary_proof_verification,
  stew/results
  

type
  MptProof = seq[seq[byte]]
  AccountProof* = distinct MptProof
  StorageProof* = distinct MptProof


proc verifyAccount*(
    trustedStateRoot: KeccakHash,
    address: EthAddress,
    account: Account,
    proof: AccountProof): Result[void, string] =
  assert trustedStateRoot.data.len() > 0
  assert address.len() > 0
  assert proof.MptProof.len() > 0

  let key = toSeq(keccakHash(address).data)
  let value = rlp.encode(account)

  let proofResult = verifyMptProof(proof.MptProof, trustedStateRoot, key, value)

  case proofResult.kind
  of ValidProof:
    ok()
  of MissingKey:
    # For an account that doesn't exist yet, which is fine.
    ok()
  of InvalidProof:
    err(proofResult.errorMsg)


proc verifyContractStorageSlot*(
    trustedStorageRoot: KeccakHash,
    slotKey: UInt256,
    slotValue: UInt256,
    proof: StorageProof): Result[void, string] =
  assert trustedStorageRoot.data.len() > 0
  assert proof.MptProof.len() > 0

  let key = toSeq(keccakHash(toBytesBE(slotKey)).data)
  let value = rlp.encode(slotValue)

  let proofResult = verifyMptProof(proof.MptProof, trustedStorageRoot, key, value)

  case proofResult.kind
  of ValidProof:
    ok()
  of MissingKey:
    # This is for a slot that doesn't have anything stored at it, but that's fine.
    ok()
  of InvalidProof:
    err(proofResult.errorMsg)


proc verifyContractBytecode*(trustedCodeHash: KeccakHash, bytecode: seq[byte]): Result[void, string] =
  assert trustedCodeHash.data.len() > 0
  assert bytecode.len() > 0

  if trustedCodeHash == keccakHash(bytecode):
    ok()
  else:
    err("hash of bytecode doesn't match the expected code hash")