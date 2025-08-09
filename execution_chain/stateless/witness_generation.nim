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
  minilru,
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
    preStateLedger: LedgerRef): T =
  var
    witness = Witness.init()
    addedCodeHashes: HashSet[Hash32]
    proofPaths: Table[Hash32, seq[Hash32]]

  for key, codeTouched in witnessKeys:
    if key.slot.isNone(): # Is an account key
      let addressBytes = key.address.data()
      witness.addKey(addressBytes)

      if codeTouched:
        let codeHash = preStateLedger.getCodeHash(key.address)
        if codeHash != EMPTY_CODE_HASH and codeHash notin addedCodeHashes:
          witness.addCodeHash(codeHash)
          addedCodeHashes.incl(codeHash)

      # Add the storage paths for this account
      var storagePaths: seq[Hash32]
      for key2, codeTouched2 in witnessKeys:
        if key2.address == key.address and key2.slot.isSome():
          let slotBytes = key2.slot.get().toBytesBE()
          witness.addKey(slotBytes)
          storagePaths.add(keccak256(slotBytes))

      proofPaths[keccak256(addressBytes)] = storagePaths

  witness.state = preStateLedger.txFrame.multiProof(proofPaths).valueOr:
    raiseAssert "Failed to get multiproof: " & $$error

  witness

proc getEarliestCachedBlockNumber(blockHashes: BlockHashesCache): Opt[BlockNumber] =
  if blockHashes.len() == 0:
    return Opt.none(BlockNumber)

  var earliestBlockNumber = high(BlockNumber)
  for blockNumber in blockHashes.keys():
    if blockNumber < earliestBlockNumber:
      earliestBlockNumber = blockNumber

  Opt.some(earliestBlockNumber)

proc build*(
    T: type Witness,
    preStateLedger: LedgerRef,
    ledger: LedgerRef,
    parent: Header,
    header: Header,
    validateStateRoot = false): T =

  if validateStateRoot and parent.number > 0:
    doAssert preStateLedger.getStateRoot() == parent.stateRoot

  var witness = Witness.build(ledger.getWitnessKeys(), preStateLedger)
  witness.addHeaderHash(header.parentHash)

  let
    blockHashes = ledger.getBlockHashesCache()
    earliestBlockNumber = getEarliestCachedBlockNumber(blockHashes)
  if earliestBlockNumber.isSome():
    var n = parent.number - 1
    while n >= earliestBlockNumber.get():
      let blockHash = ledger.getBlockHash(BlockNumber(n))
      doAssert(blockHash != default(Hash32))
      witness.addHeaderHash(blockHash)
      dec n
