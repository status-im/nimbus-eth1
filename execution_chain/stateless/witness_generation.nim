# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, sets],
  eth/common,
  eth/rlp,
  results,
  ../db/ledger,
  ./witness

export
  common,
  results,
  ledger

{.push raises: [].}

func build*(
    T: type Witness,
    ledger: LedgerRef,
    codes: var openArray[byte]): T =
  var
    witness = Witness.init()
    addedStateHashes = initHashSet[Hash32]()
    addedCodeHashes = initHashSet[Hash32]()

  for key in ledger.getWitnessKeys().values():
    if key.storageMode:
      witness.addKey(key.storageSlot.toBytesBE())

      let proofs = ledger.getStorageProof(key.address, @[key.storageSlot])
      doAssert(proofs.len() == 1)
      for trieNode in proofs[0]:
        let nodeHash = keccak256(trieNode)
        if nodeHash notin addedStateHashes:
          witness.addState(trieNode)
          addedStateHashes.incl(nodeHash)
    else:
      witness.addKey(key.address.toBytes())

      let proof = ledger.getAccountProof(key.address)
      for trieNode in proof:
        let nodeHash = keccak256(trieNode)
        if nodeHash notin addedStateHashes:
          witness.addState(trieNode)
          addedStateHashes.incl(nodeHash)

    if key.codeTouched:
      let (codeHash, code) = ledger.getCode(key.address, returnHash = true)
      if codeHash != EMPTY_CODE_HASH and codeHash notin addedCodeHashes:
        codes.add(code.bytes)
        witness.addCodeHash(codeHash)
        addedCodeHashes.incl(codeHash)

  witness

# func build*(
#     T: type ExecutionWitness,
#     ledger: LedgerRef,
#     headers: openArray[Header]): T =
#   var
#     witness = ExecutionWitness.init()
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
