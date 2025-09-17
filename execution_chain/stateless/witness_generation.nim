# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets],
  minilru,
  eth/common,
  ../db/[ledger, core_db],
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
    accPreimages: Table[Hash32, array[20, byte]]
    stoPreimages: Table[Hash32, array[32, byte]]
    witness = Witness.init()

  for key, (codeTouched, _) in witnessKeys:
    let
      addressBytes = key.address.data()
      accPath = keccak256(addressBytes)
    accPreimages[accPath] = addressBytes

    if key.slot.isNone(): # Is an account key
      proofPaths.withValue(accPath, v):
        discard v
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
      stoPreimages[slotPath] = slotBytes

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

  for accPath, stoPaths in proofPaths:
    witness.addKey(accPreimages.getOrDefault(accPath))
    for stoPath in stoPaths:
      witness.addKey(stoPreimages.getOrDefault(stoPath))

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
    var n = parent.number
    while n >= earliestBlockNumber.get():
      dec n
      let blockHash = ledger.getBlockHash(BlockNumber(n))
      doAssert(blockHash != default(Hash32))
      witness.addHeaderHash(blockHash)

  witness


proc build*(T: type ExecutionWitness, witness: Witness, ledger: LedgerRef): ExecutionWitness =
  var codes: seq[seq[byte]]
  for codeHash in witness.codeHashes:
    let code = ledger.txFrame.getCodeByHash(codeHash).valueOr:
      raiseAssert "Code not found"
    codes.add(code)

  var headers: seq[seq[byte]]
  for headerHash in witness.headerHashes:
    let header = ledger.txFrame.getBlockHeader(headerHash).valueOr:
      raiseAssert "Header not found"
    headers.add(rlp.encode(header))

  ExecutionWitness.init(
    state = witness.state,
    codes = move(codes),
    keys = witness.keys,
    headers = move(headers))
