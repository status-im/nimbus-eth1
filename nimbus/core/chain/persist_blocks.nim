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
  ../../db/ledger,
  ../../vm_state,
  ../../vm_types,
  ../clique/clique_verify,
  ../clique,
  ../executor,
  ../validate,
  ./chain_desc,
  chronicles,
  stint

when not defined(release):
  import
    ../../tracer,
    ../../utils/utils

type
  PersistBlockFlag = enum
    NoPersistHeader
    NoSaveTxs
    NoSaveReceipts
    NoSaveWithdrawals

  PersistBlockFlags = set[PersistBlockFlag]

var
  noisy* = false

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc getVmState(c: ChainRef, header: BlockHeader):
                 Result[BaseVMState, void]
                  {.gcsafe, raises: [CatchableError].} =
  if c.vmState.isNil.not:
    return ok(c.vmState)

  let vmState = BaseVMState()
  if not vmState.init(header, c.com):
    debug "Cannot initialise VmState",
      number = header.blockNumber
    return err()
  return ok(vmState)

proc persistBlocksImpl(c: ChainRef; headers: openArray[BlockHeader];
                       bodies: openArray[BlockBody],
                       flags: PersistBlockFlags = {}): ValidationResult
                          # wildcard exception, wrapped below in public section
                          {.inline, raises: [CatchableError].} =

  let dbTx = c.db.beginTransaction()
  defer: dbTx.dispose()

  var cliqueState = c.clique.cliqueSave
  defer: c.clique.cliqueRestore(cliqueState)

  c.com.hardForkTransition(headers[0])

  # Note that `0 < headers.len`, assured when called from `persistBlocks()`
  let vmState = c.getVmState(headers[0]).valueOr:
    return ValidationResult.Error

  trace "Persisting blocks",
    fromBlock = headers[0].blockNumber,
    toBlock = headers[^1].blockNumber

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
      return ValidationResult.Error

    if c.validateBlock and c.extraValidation and
       c.verifyFrom <= header.blockNumber:

      if c.com.consensus != ConsensusType.POA:
        let res = c.com.validateHeaderAndKinship(
          header,
          body,
          checkSealOK = false) # TODO: how to checkseal from here
        if res.isErr:
          debug "block validation error",
            msg = res.error
          return ValidationResult.Error

    if c.generateWitness:
      vmState.generateWitness = true

    let
      validationResult = if c.validateBlock or c.generateWitness:
                           vmState.processBlock(header, body)
                         else:
                           ValidationResult.OK
    when not defined(release):
      if validationResult == ValidationResult.Error and
         body.transactions.calcTxRoot == header.txRoot:
        vmState.dumpDebuggingMetaData(header, body)
        warn "Validation error. Debugging metadata dumped."

    if validationResult != ValidationResult.OK:
      return validationResult

    if c.validateBlock and c.extraValidation and
       c.verifyFrom <= header.blockNumber:

      if c.com.consensus == ConsensusType.POA:
        var parent = if 0 < i: @[headers[i-1]] else: @[]
        let rc = c.clique.cliqueVerify(c.com, header, parent)
        if rc.isOk:
          # mark it off so it would not auto-restore previous state
          c.clique.cliqueDispose(cliqueState)
        else:
          debug "PoA header verification failed",
            blockNumber = header.blockNumber,
            msg = $rc.error
          return ValidationResult.Error

    when defined(release).not and true: # and false:
      let num = header.blockNumber.truncate(uint64)
      #if 81984 < num and (num mod 7000) == 500:
      if (num mod 500) == 0:
        const noisy = true
        if noisy: debugEcho ">>> persistBlocksImpl (1)",
          " #", header.blockNumber,
          " i=", i
        vmState.dumpDebuggingMetaData(header, body)
        info "Validation OK. Debugging metadata dumped."
        if noisy: debugEcho "<<< persistBlocksImpl (9) #", header.blockNumber

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

  dbTx.commit()

# ------------------------------------------------------------------------------
# Public `ChainDB` methods
# ------------------------------------------------------------------------------

proc insertBlockWithoutSetHead*(c: ChainRef, header: BlockHeader,
                                body: BlockBody): ValidationResult
                                {.gcsafe, raises: [CatchableError].} =
  result = c.persistBlocksImpl(
    [header], [body], {NoPersistHeader, NoSaveReceipts})
  if result == ValidationResult.OK:
    c.db.persistHeaderToDbWithoutSetHead(header, c.com.startOfHistory)

proc setCanonical*(c: ChainRef, header: BlockHeader): ValidationResult
                                {.gcsafe, raises: [CatchableError].} =

  if header.parentHash == Hash256():
    discard c.db.setHead(header.blockHash)
    return ValidationResult.OK

  var body: BlockBody
  if not c.db.getBlockBody(header, body):
    debug "Failed to get BlockBody",
      hash = header.blockHash
    return ValidationResult.Error

  result = c.persistBlocksImpl([header], [body], {NoPersistHeader, NoSaveTxs})
  if result == ValidationResult.OK:
    discard c.db.setHead(header.blockHash)

proc setCanonical*(c: ChainRef, blockHash: Hash256): ValidationResult
                                {.gcsafe, raises: [CatchableError].} =
  var header: BlockHeader
  if not c.db.getBlockHeader(blockHash, header):
    debug "Failed to get BlockHeader",
      hash = blockHash
    return ValidationResult.Error

  setCanonical(c, header)

proc persistBlocks*(c: ChainRef; headers: openArray[BlockHeader];
                      bodies: openArray[BlockBody]): ValidationResult
                        {.gcsafe, raises: [CatchableError].} =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return ValidationResult.Error

  if headers.len == 0:
    debug "Nothing to do"
    return ValidationResult.OK

  c.persistBlocksImpl(headers,bodies)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
