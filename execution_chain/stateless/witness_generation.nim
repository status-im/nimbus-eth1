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
    proofPaths: Table[Hash32, seq[Hash32]]
    addedCodeHashes: HashSet[Hash32]
    witness = Witness.init()

  for key, codeTouched in witnessKeys:
    let
      addressBytes = key.address.data()
      accPath = keccak256(addressBytes)

    if key.slot.isNone(): # Is an account key
      witness.addKey(key.address.data())

      proofPaths.withValue(accPath, v):
        discard
      do:
        proofPaths[accPath] = @[]

      # codeTouched is only set for account keys
      if codeTouched:
        let codeHash = preStateLedger.getCodeHash(key.address)
        if codeHash != EMPTY_CODE_HASH and codeHash notin addedCodeHashes:
          witness.addCodeHash(codeHash)
          addedCodeHashes.incl(codeHash)

    else: # Is a slot key
      let
        slotBytes = key.slot.get().toBytesBE()
        slotPath = keccak256(slotBytes)

      witness.addKey(slotBytes)

      proofPaths.withValue(accPath, v):
        v[].add(slotPath)
      do:
        var paths: seq[Hash32]
        paths.add(slotPath)
        proofPaths[accPath] = paths

  var multiProof: seq[seq[byte]]
  preStateLedger.txFrame.multiProof(proofPaths, multiProof).isOkOr:
    raiseAssert "Failed to get multiproof: " & $$error

  witness.state = move(multiProof)
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
