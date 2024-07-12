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
  ../../evm/state,
  ../../evm/types,
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
  PersistBlockFlag* = enum
    NoValidation # Validate the batch instead of validating each block in it
    NoFullValidation # Validate the batch instead of validating each block in it
    NoPersistHeader
    NoPersistTransactions
    NoPersistUncles
    NoPersistWithdrawals
    NoPersistReceipts

  PersistBlockFlags* = set[PersistBlockFlag]

  PersistStats = tuple[blocks: int, txs: int, gas: GasInt]

const
  NoPersistBodies* = {NoPersistTransactions, NoPersistUncles, NoPersistWithdrawals}

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
  let dbTx = c.db.ctx.newTransaction()
  defer:
    dbTx.dispose()

  c.com.hardForkTransition(blocks[0].header)

  # Note that `0 < headers.len`, assured when called from `persistBlocks()`
  let
    vmState = ?c.getVmState(blocks[0].header)
    fromBlock = blocks[0].header.number
    toBlock = blocks[blocks.high()].header.number
  trace "Persisting blocks", fromBlock, toBlock

  var
    blks = 0
    txs = 0
    gas = GasInt(0)
    parentHash: Hash256 # only needed after the first block
  for blk in blocks:
    template header(): BlockHeader =
      blk.header

    # Full validation means validating the state root at every block and
    # performing the more expensive hash computations on the block itself, ie
    # verifying that the transaction and receipts roots are valid - when not
    # doing full validation, we skip these expensive checks relying instead
    # on the source of the data to have performed them previously or because
    # the cost of failure is low.
    # TODO Figure out the right balance for header fields - in particular, if
    #      we receive instruction from the CL while syncing that a block is
    #      CL-valid, do we skip validation while "far from head"? probably yes.
    #      This requires performing a header-chain validation from that CL-valid
    #      block which the current code doesn't express.
    #      Also, the potential avenues for corruption should be described with
    #      more rigor, ie if the txroot doesn't match but everything else does,
    #      can the state root of the last block still be correct? Dubious, but
    #      what would be the consequences? We would roll back the full set of
    #      blocks which is fairly low-cost.
    let skipValidation =
      NoFullValidation in flags and header.number != toBlock or NoValidation in flags

    c.com.hardForkTransition(header)

    if blks > 0:
      template parent(): BlockHeader =
        blocks[blks - 1].header

      let updated =
        if header.number == parent.number + 1 and header.parentHash == parentHash:
          vmState.reinit(parent = parent, header = header, linear = true)
        else:
          # TODO remove this code path and process only linear histories in this
          #      function
          vmState.reinit(header = header)

      if not updated:
        debug "Cannot update VmState", blockNumber = header.number
        return err("Cannot update VmState to block " & $header.number)

    # TODO even if we're skipping validation, we should perform basic sanity
    #      checks on the block and header - that fields are sanely set for the
    #      given hard fork and similar path-independent checks - these same
    #      sanity checks should be performed early in the processing pipeline no
    #      matter their provenance.
    if not skipValidation and c.extraValidation and c.verifyFrom <= header.number:
      # TODO: how to checkseal from here
      ?c.com.validateHeaderAndKinship(blk, vmState.parent, checkSealOK = false)

    # Generate receipts for storage or validation but skip them otherwise
    ?vmState.processBlock(
      blk,
      skipValidation,
      skipReceipts = skipValidation and NoPersistReceipts in flags,
      skipUncles = NoPersistUncles in flags,
    )

    # when defined(nimbusDumpDebuggingMetaData):
    #   if validationResult == ValidationResult.Error and
    #      body.transactions.calcTxRoot == header.txRoot:
    #     vmState.dumpDebuggingMetaData(header, body)
    #     warn "Validation error. Debugging metadata dumped."

    let blockHash = header.blockHash()
    if NoPersistHeader notin flags:
      if not c.db.persistHeader(
        blockHash, header, c.com.consensus == ConsensusType.POS, c.com.startOfHistory
      ):
        return err("Could not persist header")

    if NoPersistTransactions notin flags:
      c.db.persistTransactions(header.number, header.txRoot, blk.transactions)

    if NoPersistReceipts notin flags:
      c.db.persistReceipts(header.receiptsRoot, vmState.receipts)

    if NoPersistWithdrawals notin flags and blk.withdrawals.isSome:
      c.db.persistWithdrawals(
        header.withdrawalsRoot.expect("WithdrawalsRoot should be verified before"),
        blk.withdrawals.get,
      )

    # update currentBlock *after* we persist it
    # so the rpc return consistent result
    # between eth_blockNumber and eth_syncing
    c.com.syncCurrent = header.number

    blks += 1
    txs += blk.transactions.len
    gas += blk.header.gasUsed
    parentHash = blockHash

  dbTx.commit()

  # Save and record the block number before the last saved block state.
  c.db.persistent(toBlock).isOkOr:
    return err("Failed to save state: " & $$error)

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

  ok((blks, txs, gas))

# ------------------------------------------------------------------------------
# Public `ChainDB` methods
# ------------------------------------------------------------------------------

proc insertBlockWithoutSetHead*(c: ChainRef, blk: EthBlock): Result[void, string] =
  discard ?c.persistBlocksImpl([blk], {NoPersistHeader, NoPersistReceipts})

  if not c.db.persistHeader(blk.header.blockHash, blk.header, c.com.startOfHistory):
    return err("Could not persist header")

  ok()

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
      [EthBlock.init(header, move(body))], {NoPersistHeader, NoPersistTransactions}
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
    c: ChainRef, blocks: openArray[EthBlock], flags: PersistBlockFlags = {}
): Result[PersistStats, string] =
  # Run the VM here
  if blocks.len == 0:
    debug "Nothing to do"
    return ok(default(PersistStats)) # TODO not nice to return nil

  c.persistBlocksImpl(blocks, flags)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
