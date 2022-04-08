# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../db/db_chain,
  ../../vm_state,
  ../../vm_types,
  ../clique,
  ../executor,
  ../validate,
  ./chain_desc,
  ./chain_helpers,
  chronicles,
  eth/[common, trie/db],
  stew/endians2,
  stint

when not defined(release):
  import
    ../../tracer,
    ../../utils

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc persistBlocksImpl(c: Chain; headers: openArray[BlockHeader];
                       bodies: openArray[BlockBody], setHead: bool = true): ValidationResult
                          # wildcard exception, wrapped below in public section
                          {.inline, raises: [Exception].} =
  c.db.highestBlock = headers[^1].blockNumber
  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks",
    fromBlock = headers[0].blockNumber,
    toBlock = headers[^1].blockNumber

  var cliqueState = c.clique.cliqueSave
  defer: c.clique.cliqueRestore(cliqueState)

  # Note that `0 < headers.len`, assured when called from `persistBlocks()`
  var vmState = BaseVMState.new(headers[0], c.db)

  for i in 0 ..< headers.len:
    let
      (header, body) = (headers[i], bodies[i])

    if not vmState.reinit(header):
      debug "Cannot update VmState",
        blockNumber = header.blockNumber,
        item = i
      return ValidationResult.Error

    let
      validationResult = vmState.processBlock(c.clique, header, body)

    when not defined(release):
      if validationResult == ValidationResult.Error and
         body.transactions.calcTxRoot == header.txRoot:
        dumpDebuggingMetaData(c.db, header, body, vmState)
        warn "Validation error. Debugging metadata dumped."

    if validationResult != ValidationResult.OK:
      return validationResult

    if c.extraValidation and c.verifyFrom <= header.blockNumber:
      let isBlockAfterTtd = c.isBlockAfterTtd(header)
      if c.db.config.poaEngine and not isBlockAfterTtd:
        var parent = if 0 < i: @[headers[i-1]] else: @[]
        let rc = c.clique.cliqueVerify(header,parent)
        if rc.isOk:
          # mark it off so it would not auto-restore previous state
          c.clique.cliqueDispose(cliqueState)
        else:
          debug "PoA header verification failed",
            blockNumber = header.blockNumber,
            msg = $rc.error
          return ValidationResult.Error
      else:
        let res = c.db.validateHeaderAndKinship(
          header,
          body,
          checkSealOK = false, # TODO: how to checkseal from here
          ttdReached = isBlockAfterTtd,
          pow = c.pow)
        if res.isErr:
          debug "block validation error",
            msg = res.error
          return ValidationResult.Error

    if setHead:
      discard c.db.persistHeaderToDb(header)
    else:
      c.db.persistHeaderToDbWithoutSetHead(header)

    discard c.db.persistTransactions(header.blockNumber, body.transactions)
    discard c.db.persistReceipts(vmState.receipts)

    # update currentBlock *after* we persist it
    # so the rpc return consistent result
    # between eth_blockNumber and eth_syncing
    c.db.currentBlock = header.blockNumber

  transaction.commit()

# ------------------------------------------------------------------------------
# Public `ChainDB` methods
# ------------------------------------------------------------------------------

proc insertBlockWithoutSetHead*(c: Chain, header: BlockHeader,
                                body: BlockBody): ValidationResult
                                {.gcsafe, raises: [Defect,CatchableError].} =

  safeP2PChain("persistBlocks"):
    result = c.persistBlocksImpl([header], [body], setHead = false)

# ------------------------------------------------------------------------------
# Public `AbstractChainDB` overload method
# ------------------------------------------------------------------------------

method persistBlocks*(c: Chain; headers: openArray[BlockHeader];
                      bodies: openArray[BlockBody]): ValidationResult
                        {.gcsafe, raises: [Defect,CatchableError].} =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return ValidationResult.Error

  if headers.len == 0:
    debug "Nothing to do"
    return ValidationResult.OK

  safeP2PChain("persistBlocks"):
    result = c.persistBlocksImpl(headers,bodies)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
