# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/tables,
  eth/rlp,
  results

export
  results

{.push raises: [].}

type
  Witness* = object
    state*: seq[seq[byte]] # MPT trie nodes accessed while executing the block.
    keys*: seq[seq[byte]] # Ordered list of access keys (address bytes or storage slots bytes).

func init*(
    T: type Witness,
    state = newSeq[seq[byte]](),
    keys = newSeq[seq[byte]]()): T =
  Witness(state: state, keys: keys)

template addState*(witness: var Witness, trieNode: seq[byte]) =
  witness.state.add(trieNode)

template addKey*(witness: var Witness, key: seq[byte]) =
  witness.keys.add(key)

func encode*(witness: Witness): seq[byte] =
  rlp.encode(witness)

func decode*(T: type Witness, witnessBytes: openArray[byte]): Result[T, string] =
  try:
    ok(rlp.decode(witnessBytes, T))
  except RlpError as e:
    err(e.msg)

# func build*(
#     T: type Witness,
#     ledger: LedgerRef,
#     headers: openArray[Header]): T =
#   var
#     witness = Witness.init()
#     addedStateHashes = initHashSet[Hash32]()
#     addedCodeHashes = initHashSet[Hash32]()

#   for key in ledger.getWitnessKeys().values():
#     if key.storageMode:
#       witness.addKey(key.storageSlot.toBytesBE())

#       let proofs = ledger.getStorageProof(key.address, @[key.storageSlot])
#       doAssert(proofs.len() == 1)
#       for trieNode in proofs[0]:
#         let nodeHash = keccak256(trieNode)
#         if nodeHash notin addedStateHashes:
#           witness.addState(trieNode)
#           addedStateHashes.incl(nodeHash)
#     else:
#       witness.addKey(key.address.toBytes())

#       let proof = ledger.getAccountProof(key.address)
#       for trieNode in proof:
#         let nodeHash = keccak256(trieNode)
#         if nodeHash notin addedStateHashes:
#           witness.addState(trieNode)
#           addedStateHashes.incl(nodeHash)

#     if key.codeTouched:
#       let (codeHash, code) = ledger.getCode(key.address, returnHash = true)
#       if codeHash != EMPTY_CODE_HASH and codeHash notin addedCodeHashes:
#         witness.addCode(code.bytes)
#         addedCodeHashes.incl(codeHash)

#   for h in headers:
#     witness.addHeader(h)

#   witness
