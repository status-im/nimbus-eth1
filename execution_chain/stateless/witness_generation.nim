# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[tables, sets],
  eth/common,
  ../db/ledger,
  ./witness_types

export
  common,
  ledger,
  witness_types

proc build*(
    T: type Witness,
    witnessKeys: WitnessTable,
    ledger: ReadOnlyLedger): T =
  var
    witness = Witness.init()
    addedStateHashes = initHashSet[Hash32]()
    addedCodeHashes = initHashSet[Hash32]()

  for key, codeTouched in witnessKeys:
    if key.slot.isNone(): # Is an account key
      witness.addKey(key.address.data())

      let proof = ledger.getAccountProof(key.address)
      for trieNode in proof:
        let nodeHash = keccak256(trieNode)
        if nodeHash notin addedStateHashes:
          witness.addState(trieNode)
          addedStateHashes.incl(nodeHash)

      if codeTouched:
        let codeHash = ledger.getCodeHash(key.address)
        if codeHash != EMPTY_CODE_HASH and codeHash notin addedCodeHashes:
          witness.addCodeHash(codeHash)
          addedCodeHashes.incl(codeHash)

      # Add the storage slots for this account
      for key2, codeTouched2 in witnessKeys:
        if key2.address == key.address and key2.slot.isSome():
          let slot = key2.slot.get()
          witness.addKey(slot.toBytesBE())

          let proofs = ledger.getStorageProof(key.address, @[slot])
          doAssert(proofs.len() == 1)
          for trieNode in proofs[0]:
            let nodeHash = keccak256(trieNode)
            if nodeHash notin addedStateHashes:
              witness.addState(trieNode)
              addedStateHashes.incl(nodeHash)

  witness
