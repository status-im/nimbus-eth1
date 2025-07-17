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
    let (_, maybeSlot) = key
    if maybeSlot.isSome():
      let slot = maybeSlot.get()
      witness.addKey(slot.toBytesBE())

      let proofs = ledger.getStorageProof(key.address, @[slot])
      doAssert(proofs.len() == 1)
      for trieNode in proofs[0]:
        let nodeHash = keccak256(trieNode)
        if nodeHash notin addedStateHashes:
          witness.addState(trieNode)
          addedStateHashes.incl(nodeHash)
    else:
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

  witness
