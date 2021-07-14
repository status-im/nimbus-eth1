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
  ../../utils,
  ../../vm_state,
  ../clique,
  ../executor,
  ../validate,
  ./chain_desc,
  ./chain_helpers,
  chronicles,
  eth/[common, trie/db],
  nimcrypto,
  stew/endians2,
  stint

# debugging clique
when defined(debug):
  import
    std/[algorithm, strformat, strutils],
    ../clique/clique_desc

when not defined(release):
  import ../../tracer

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc persistBlocksImpl(c: Chain; headers: openarray[BlockHeader];
                       bodies: openarray[BlockBody]): ValidationResult
                          # wildcard exception, wrapped below
                          {.inline, raises: [Exception].} =
  c.db.highestBlock = headers[^1].blockNumber
  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks",
    fromBlock = headers[0].blockNumber,
    toBlock = headers[^1].blockNumber

  for i in 0 ..< headers.len:
    let
      (header, body) = (headers[i], bodies[i])
      parentHeader = c.db.getBlockHeader(header.parentHash)
      vmState = newBaseVMState(parentHeader.stateRoot, header, c.db)

      # The following processing function call will update the PoA state which
      # is passed as second function argument. The PoA state is ignored for
      # non-PoA networks (in which case `vmState.processBlock(header,body)`
      # would also be correct but not vice versa.)
      validationResult = vmState.processBlock(c.clique, header, body)

    when not defined(release):
      if validationResult == ValidationResult.Error and
         body.transactions.calcTxRoot == header.txRoot:
        dumpDebuggingMetaData(c.db, header, body, vmState)
        warn "Validation error. Debugging metadata dumped."

    if validationResult != ValidationResult.OK:
      return validationResult

    if c.extraValidation:
      let res = c.db.validateHeaderAndKinship(
        header,
        body,
        checkSealOK = false, # TODO: how to checkseal from here
        c.cacheByEpoch
      )
      if res.isErr:
        debug "block validation error", msg = res.error
        return ValidationResult.Error

    discard c.db.persistHeaderToDb(header)
    discard c.db.persistTransactions(header.blockNumber, body.transactions)
    discard c.db.persistReceipts(vmState.receipts)

    # update currentBlock *after* we persist it
    # so the rpc return consistent result
    # between eth_blockNumber and eth_syncing
    c.db.currentBlock = header.blockNumber

  if c.db.config.poaEngine:
    if c.clique.cliqueSnapshot(headers[^1]).isErr:
      debug "PoA signer snapshot failed"
    when defined(debug):
      #let list = c.clique.pp(c.clique.cliqueSigners).sorted
      #echo &"*** {list.len} trusted signer(s): ", list.join(" ")
      discard

  transaction.commit()

# ------------------------------------------------------------------------------
# Public `AbstractChainDB` overload method
# ------------------------------------------------------------------------------

method persistBlocks*(c: Chain; headers: openarray[BlockHeader];
                      bodies: openarray[BlockBody]): ValidationResult
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
