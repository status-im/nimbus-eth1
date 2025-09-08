# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/byteutils,
  eth/rlp,
  eth/common/keys,
  web3/eth_api,
  ../execution_chain/db/aristo/aristo_proof

template toHash32*(hash: untyped): Hash32 =
  fromHex(Hash32, hash.toHex())

proc verifyAccountLeafExists*(trustedStateRoot: Hash32, res: ProofResponse): bool =
  let
    accPath = keccak256(res.address.data)
    value = rlp.encode(Account(
        nonce: res.nonce.uint64,
        balance: res.balance,
        storageRoot: res.storageHash.toHash32(),
        codeHash: res.codeHash.toHash32()))

  let accLeaf = verifyProof(seq[seq[byte]](res.accountProof), trustedStateRoot, accPath).expect("valid proof")
  accLeaf.isSome() and accLeaf.get() == value

proc verifyAccountLeafMissing*(trustedStateRoot: Hash32, res: ProofResponse): bool =
  let
    accPath = keccak256(res.address.data)
    value = rlp.encode(Account(
        nonce: res.nonce.uint64,
        balance: res.balance,
        storageRoot: res.storageHash.toHash32(),
        codeHash: res.codeHash.toHash32()))

  let accLeaf = verifyProof(seq[seq[byte]](res.accountProof), trustedStateRoot, accPath).expect("valid proof")
  accLeaf.isNone()

proc verifySlotLeafExists*(trustedStorageRoot: Hash32, slot: StorageProof): bool =
  let
    slotPath = keccak256(toBytesBE(slot.key))
    value = rlp.encode(slot.value)

  let slotLeaf = verifyProof(seq[seq[byte]](slot.proof), trustedStorageRoot, slotPath).expect("valid proof")
  slotLeaf.isSome() and slotLeaf.get() == value

proc verifySlotLeafMissing*(trustedStorageRoot: Hash32, slot: StorageProof): bool =
  let
    slotPath = keccak256(toBytesBE(slot.key))
    value = rlp.encode(slot.value)

  let slotLeaf = verifyProof(seq[seq[byte]](slot.proof), trustedStorageRoot, slotPath).expect("valid proof")
  slotLeaf.isNone()
