# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  results,
  ../../db/ledger,
  ../../vm_state,
  ../../vm_types,
  ../executor,
  ../validate,
  ./chain_desc,
  chronicles,
  stint

when not defined(release):
  import
    ../../tracer,
    ../../utils/utils

export results

type
  PersistBlockFlag = enum
    NoPersistHeader
    NoSaveTxs
    NoSaveReceipts
    NoSaveWithdrawals

  PersistBlockFlags = set[PersistBlockFlag]

  PersistStats = tuple
    blocks: int
    txs: int
    gas: GasInt

const
  CleanUpEpoch = 30_000.toBlockNumber
    ## Regular checks for history clean up (applies to single state DB). This
    ## is mainly a debugging/testing feature so that the database can be held
    ## a bit smaller. It is not applicable to a full node.

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc getVmState(c: ChainRef, header: BlockHeader):
                Result[BaseVMState, string] =
  let vmState = BaseVMState()
  try:
    # TODO clean up exception handling
    if not vmState.init(header, c.com):
      return err("Could not initialise VMState")
  except CatchableError as exc:
    return err("Error while initializing VMState: " & exc.msg)

  ok(vmState)

proc purgeOlderBlocksFromHistory(
    db: CoreDbRef;
    bn: BlockNumber;
      ) {.inline, raises: [RlpError].} =
  ## Remove non-reachable blocks from KVT database
  if 0 < bn:
    var blkNum = bn - 1
    while 0 < blkNum:
      if not db.forgetHistory blkNum:
        break
      blkNum = blkNum - 1

proc persistBlocksImpl(c: ChainRef; headers: openArray[BlockHeader];
                       bodies: openArray[BlockBody],
                       flags: PersistBlockFlags = {}): Result[PersistStats, string]
                         {.raises: [CatchableError] .} =
  let dbTx = c.db.beginTransaction()
  defer: dbTx.dispose()

  c.com.hardForkTransition(headers[0])

  # Note that `0 < headers.len`, assured when called from `persistBlocks()`
  let vmState = ?c.getVmState(headers[0])

  let (fromBlock, toBlock) = (headers[0].blockNumber, headers[^1].blockNumber)
  trace "Persisting blocks", fromBlock, toBlock

  var txs = 0
  for i in 0 ..< headers.len:
    let (header, body) = (headers[i], bodies[i])

    # This transaction keeps the current state open for inspection
    # if an error occurs (as needed for `Aristo`.).
    let lapTx = c.db.beginTransaction()
    defer: lapTx.dispose()

    c.com.hardForkTransition(header)

    if not vmState.reinit(header):
      debug "Cannot update VmState",
        blockNumber = header.blockNumber,
        item = i
      return err("Cannot update VmState to block " & $header.blockNumber)

    if c.validateBlock and c.extraValidation and
       c.verifyFrom <= header.blockNumber:

      ? c.com.validateHeaderAndKinship(
        header,
        body,
        checkSealOK = false) # TODO: how to checkseal from here

    if c.generateWitness:
      vmState.generateWitness = true

    let
      validationResult = if c.validateBlock or c.generateWitness:
                           vmState.processBlock(header, body)
                         else:
                           ValidationResult.OK

    when defined(nimbusDumpDebuggingMetaData):
      if validationResult == ValidationResult.Error and
         body.transactions.calcTxRoot == header.txRoot:
        vmState.dumpDebuggingMetaData(header, body)
        warn "Validation error. Debugging metadata dumped."

    if validationResult != ValidationResult.OK:
      return err("Failed to validate block")

    if c.generateWitness:
      let dbTx = c.db.beginTransaction()
      defer: dbTx.dispose()

      let
        mkeys = vmState.stateDB.makeMultiKeys()
        # Reset state to what it was before executing the block of transactions
        initialState = BaseVMState.new(header, c.com)
        witness = initialState.buildWitness(mkeys)

      dbTx.rollback()

      c.db.setBlockWitness(header.blockHash(), witness)

    if NoPersistHeader notin flags:
      discard c.db.persistHeaderToDb(
        header, c.com.consensus == ConsensusType.POS, c.com.startOfHistory)

    if NoSaveTxs notin flags:
      discard c.db.persistTransactions(header.blockNumber, body.transactions)

    if NoSaveReceipts notin flags:
      discard c.db.persistReceipts(vmState.receipts)

    if NoSaveWithdrawals notin flags and body.withdrawals.isSome:
      discard c.db.persistWithdrawals(body.withdrawals.get)

    # update currentBlock *after* we persist it
    # so the rpc return consistent result
    # between eth_blockNumber and eth_syncing
    c.com.syncCurrent = header.blockNumber

    # Done with this block
    lapTx.commit()

    txs += body.transactions.len

  dbTx.commit()

  # Save and record the block number before the last saved block state.
  c.db.persistent(headers[^1].blockNumber - 1)

  if c.com.pruneHistory:
    # There is a feature for test systems to regularly clean up older blocks
    # from the database, not appicable to a full node set up.
    let n = fromBlock div CleanUpEpoch
    if 0 < n and n < (toBlock div CleanUpEpoch):
      # Starts at around `2 * CleanUpEpoch`
      c.db.purgeOlderBlocksFromHistory(fromBlock - CleanUpEpoch)

  ok((headers.len, txs, vmState.cumulativeGasUsed))

# ------------------------------------------------------------------------------
# Public `ChainDB` methods
# ------------------------------------------------------------------------------

proc insertBlockWithoutSetHead*(c: ChainRef, header: BlockHeader,
                                body: BlockBody): Result[void, string] =
  try:
    discard ? c.persistBlocksImpl(
      [header], [body], {NoPersistHeader, NoSaveReceipts})

    c.db.persistHeaderToDbWithoutSetHead(header, c.com.startOfHistory)
    ok()
  except CatchableError as exc:
    err(exc.msg)

proc setCanonical*(c: ChainRef, header: BlockHeader): Result[void, string] =
  try:
    if header.parentHash == Hash256():
      discard c.db.setHead(header.blockHash)
      return ok()

    var body: BlockBody
    if not c.db.getBlockBody(header, body):
      debug "Failed to get BlockBody",
        hash = header.blockHash
      return err("Could not get block body")

    discard ? c.persistBlocksImpl([header], [body], {NoPersistHeader, NoSaveTxs})

    discard c.db.setHead(header.blockHash)
    ok()
  except CatchableError as exc:
    err(exc.msg)

proc setCanonical*(c: ChainRef, blockHash: Hash256): Result[void, string] =
  var header: BlockHeader
  if not c.db.getBlockHeader(blockHash, header):
    debug "Failed to get BlockHeader",
      hash = blockHash
    return err("Could not get block header")

  setCanonical(c, header)

proc persistBlocks*(c: ChainRef; headers: openArray[BlockHeader];
                      bodies: openArray[BlockBody]): Result[PersistStats, string] =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return err("Mismatching headers and bodies")

  if headers.len == 0:
    debug "Nothing to do"
    return ok(default(PersistStats)) # TODO not nice to return nil

  try:
    c.persistBlocksImpl(headers,bodies)
  except CatchableError as exc:
    err(exc.msg)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
