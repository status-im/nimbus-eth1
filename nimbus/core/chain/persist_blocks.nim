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
    #../../tracer,
    ../../utils/utils

export results

type
  PersistBlockFlag = enum
    NoPersistHeader
    NoSaveTxs
    NoSaveReceipts
    NoSaveWithdrawals

  PersistBlockFlags = set[PersistBlockFlag]

  PersistStats = tuple[blocks: int, txs: int, gas: GasInt]

const
  CleanUpEpoch = 30_000.BlockNumber
    ## Regular checks for history clean up (applies to single state DB). This
    ## is mainly a debugging/testing feature so that the database can be held
    ## a bit smaller. It is not applicable to a full node.

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc getVmState(c: ChainRef, header: BlockHeader): Result[BaseVMState, string] =
  if not c.vmState.isNil:
    return ok(c.vmState)

  let vmState = BaseVMState()
  if not vmState.init(header, c.com):
    return err("Could not initialise VMState")
  ok(vmState)

proc purgeOlderBlocksFromHistory(db: CoreDbRef, bn: BlockNumber) =
  ## Remove non-reachable blocks from KVT database
  if 0 < bn:
    var blkNum = bn - 1
    while 0 < blkNum:
      try:
        if not db.forgetHistory blkNum:
          break
      except RlpError as exc:
        warn "Error forgetting history", err = exc.msg
      blkNum = blkNum - 1

proc persistBlocksImpl(
    c: ChainRef, blocks: openArray[EthBlock], flags: PersistBlockFlags = {}
): Result[PersistStats, string] =
  let dbTx = c.db.newTransaction()
  defer:
    dbTx.dispose()

  c.com.hardForkTransition(blocks[0].header)

  # Note that `0 < headers.len`, assured when called from `persistBlocks()`
  let vmState = ?c.getVmState(blocks[0].header)

  let
    fromBlock = blocks[0].header.number
    toBlock = blocks[blocks.high()].header.number
  trace "Persisting blocks", fromBlock, toBlock

  var txs = 0
  for blk in blocks:
    template header(): BlockHeader =
      blk.header

    c.com.hardForkTransition(header)

    if not vmState.reinit(header):
      debug "Cannot update VmState", blockNumber = header.number
      return err("Cannot update VmState to block " & $header.number)

    if c.validateBlock and c.extraValidation and c.verifyFrom <= header.number:
      # TODO: how to checkseal from here
      ?c.com.validateHeaderAndKinship(blk, checkSealOK = false)

    if c.validateBlock:
      ?vmState.processBlock(blk)

    # when defined(nimbusDumpDebuggingMetaData):
    #   if validationResult == ValidationResult.Error and
    #      body.transactions.calcTxRoot == header.txRoot:
    #     vmState.dumpDebuggingMetaData(header, body)
    #     warn "Validation error. Debugging metadata dumped."

    try:
      if NoPersistHeader notin flags:
        c.db.persistHeaderToDb(
          header, c.com.consensus == ConsensusType.POS, c.com.startOfHistory
        )

      if NoSaveTxs notin flags:
        discard c.db.persistTransactions(header.number, blk.transactions)

      if NoSaveReceipts notin flags:
        discard c.db.persistReceipts(vmState.receipts)

      if NoSaveWithdrawals notin flags and blk.withdrawals.isSome:
        discard c.db.persistWithdrawals(blk.withdrawals.get)
    except CatchableError as exc:
      return err(exc.msg)

    # update currentBlock *after* we persist it
    # so the rpc return consistent result
    # between eth_blockNumber and eth_syncing
    c.com.syncCurrent = header.number

    # Done with this block
    # lapTx.commit()

    txs += blk.transactions.len

  dbTx.commit()

  # Save and record the block number before the last saved block state.
  c.db.persistent(toBlock)

  if c.com.pruneHistory:
    # There is a feature for test systems to regularly clean up older blocks
    # from the database, not appicable to a full node set up.
    let n = fromBlock div CleanUpEpoch
    if 0 < n and n < (toBlock div CleanUpEpoch):
      # Starts at around `2 * CleanUpEpoch`
      try:
        c.db.purgeOlderBlocksFromHistory(fromBlock - CleanUpEpoch)
      except CatchableError as exc:
        warn "Could not clean up old blocks from history", err = exc.msg

  ok((blocks.len, txs, vmState.cumulativeGasUsed))

# ------------------------------------------------------------------------------
# Public `ChainDB` methods
# ------------------------------------------------------------------------------

proc insertBlockWithoutSetHead*(c: ChainRef, blk: EthBlock): Result[void, string] =
  discard ?c.persistBlocksImpl([blk], {NoPersistHeader, NoSaveReceipts})

  try:
    c.db.persistHeaderToDbWithoutSetHead(blk.header, c.com.startOfHistory)
    ok()
  except RlpError as exc:
    err(exc.msg)

proc setCanonical*(c: ChainRef, header: BlockHeader): Result[void, string] =
  if header.parentHash == Hash256():
    try:
      if not c.db.setHead(header.blockHash):
        return err("setHead failed")
    except RlpError as exc:
      # TODO fix exception+bool error return
      return err(exc.msg)
    return ok()

  var body: BlockBody
  try:
    if not c.db.getBlockBody(header, body):
      debug "Failed to get BlockBody", hash = header.blockHash
      return err("Could not get block body")
  except RlpError as exc:
    return err(exc.msg)

  discard
    ?c.persistBlocksImpl(
      [EthBlock.init(header, move(body))], {NoPersistHeader, NoSaveTxs}
    )

  try:
    discard c.db.setHead(header.blockHash)
  except RlpError as exc:
    return err(exc.msg)
  ok()

proc setCanonical*(c: ChainRef, blockHash: Hash256): Result[void, string] =
  var header: BlockHeader
  if not c.db.getBlockHeader(blockHash, header):
    debug "Failed to get BlockHeader", hash = blockHash
    return err("Could not get block header")

  setCanonical(c, header)

proc persistBlocks*(
    c: ChainRef, blocks: openArray[EthBlock]
): Result[PersistStats, string] =
  # Run the VM here
  if blocks.len == 0:
    debug "Nothing to do"
    return ok(default(PersistStats)) # TODO not nice to return nil

  c.persistBlocksImpl(blocks)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
