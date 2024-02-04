# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[options, times],
  chronicles,
  chronos,
  nimcrypto,
  stew/results,
  json_rpc/rpcclient,
  eth/[common/eth_types, p2p],
  ./core/chain/chain_desc,
  ./core/executor/process_block,
  ./db/[core_db, ledger],
  ./evm/async/[data_sources, operations, data_sources/json_rpc_data_source],
  "."/[vm_state, vm_types]

from strutils import parseInt, startsWith
from common/common import initializeEmptyDb

proc coinbasesOfThisBlockAndUncles(header: BlockHeader, body: BlockBody): seq[EthAddress] =
  result.add header.coinbase
  for uncle in body.uncles:
    result.add(uncle.coinbase)

proc createVmStateForStatelessMode*(com: CommonRef, header: BlockHeader, body: BlockBody,
                                    parentHeader: BlockHeader, asyncFactory: AsyncOperationFactory): Result[BaseVMState, string]
                                   {.inline.} =
  let vmState = BaseVMState()
  if not vmState.statelessInit(parentHeader, header, com, asyncFactory):
    return err("Cannot initialise VmState for block number " & $(header.blockNumber))
  waitFor(ifNecessaryGetAccounts(vmState, coinbasesOfThisBlockAndUncles(header, body)))
  ok(vmState)



proc statelesslyRunBlock*(asyncDataSource: AsyncDataSource, com: CommonRef, header: BlockHeader, body: BlockBody): Result[Hash256, string] =
  try:
    let t0 = now()

    # FIXME-Adam: this doesn't feel like the right place for this; where should it go?
    com.db.compensateLegacySetup()

    let blockHash: Hash256 = header.blockHash

    let asyncFactory = AsyncOperationFactory(maybeDataSource: some(asyncDataSource))

    let parentHeader = waitFor(asyncDataSource.fetchBlockHeaderWithHash(header.parentHash))
    com.db.persistHeaderToDbWithoutSetHeadOrScore(parentHeader)

    info("statelessly running block", blockNumber=header.blockNumber, blockHash=blockHash, parentHash=header.parentHash, parentStateRoot=parentHeader.stateRoot, desiredNewStateRoot=header.stateRoot)

    let vmState = createVmStateForStatelessMode(com, header, body, parentHeader, asyncFactory).get
    let vres = processBlock(vmState, header, body)

    let elapsedTime = now() - t0

    let headerStateRoot = header.stateRoot
    let vmStateRoot = rootHash(vmState.stateDB)
    info("finished statelessly running the block", vres=vres, elapsedTime=elapsedTime, durationSpentDoingFetches=durationSpentDoingFetches, fetchCounter=fetchCounter, headerStateRoot=headerStateRoot, vmStateRoot=vmStateRoot)
    if headerStateRoot != vmStateRoot:
      return err("State roots do not match: header says " & $(headerStateRoot) & ", vmState says " & $(vmStateRoot))
    else:
      if vres == ValidationResult.OK:
        return ok(blockHash)
      else:
        return err("Error while statelessly running a block")
  except:
    let ex = getCurrentException()
    echo getStackTrace(ex)
    error "Got an exception while statelessly running a block", exMsg = ex.msg
    return err("Error while statelessly running a block: " & $(ex.msg))

proc statelesslyRunBlock*(asyncDataSource: AsyncDataSource, com: CommonRef, blockHash: Hash256): Result[Hash256, string] =
  let (header, body) = waitFor(asyncDataSource.fetchBlockHeaderAndBodyWithHash(blockHash))
  let r = statelesslyRunBlock(asyncDataSource, com, header, body)
  if r.isErr:
    error("stateless execution failed", hash=blockHash, error=r.error)
  else:
    info("stateless execution succeeded", hash=blockHash, resultingHash=r.value)
  return r

proc fetchBlockHeaderAndBodyForHashOrNumber(asyncDataSource: AsyncDataSource, hashOrNum: string): Future[(BlockHeader, BlockBody)] {.async.} =
  if hashOrNum.startsWith("0x"):
    return await asyncDataSource.fetchBlockHeaderAndBodyWithHash(hashOrNum.toHash)
  else:
    return await asyncDataSource.fetchBlockHeaderAndBodyWithNumber(u256(parseInt(hashOrNum)))

proc statelesslyRunSequentialBlocks*(asyncDataSource: AsyncDataSource, com: CommonRef, initialBlockNumber: BlockNumber): Result[Hash256, string] =
  info("sequential stateless execution beginning", initialBlockNumber=initialBlockNumber)
  var n = initialBlockNumber
  while true:
    let (header, body) = waitFor(asyncDataSource.fetchBlockHeaderAndBodyWithNumber(n))
    let r = statelesslyRunBlock(asyncDataSource, com, header, body)
    if r.isErr:
      error("stateless execution failed", n=n, h=header.blockHash, error=r.error)
      return r
    else:
      info("stateless execution succeeded", n=n, h=header.blockHash, resultingHash=r.value)
      n = n + 1

proc statelesslyRunBlock*(asyncDataSource: AsyncDataSource, com: CommonRef, hashOrNum: string): Result[Hash256, string] =
  let (header, body) = waitFor(fetchBlockHeaderAndBodyForHashOrNumber(asyncDataSource, hashOrNum))
  return statelesslyRunBlock(asyncDataSource, com, header, body)


proc statelesslyRunTransaction*(asyncDataSource: AsyncDataSource, com: CommonRef, headerHash: Hash256, tx: Transaction) =
  let t0 = now()

  let (header, body) = waitFor(asyncDataSource.fetchBlockHeaderAndBodyWithHash(headerHash))

  # FIXME-Adam: this doesn't feel like the right place for this; where should it go?
  com.db.compensateLegacySetup()

  #let blockHash: Hash256 = header.blockHash

  let transaction = com.db.beginTransaction()
  defer: transaction.rollback()  # intentionally throwing away the result of this execution

  let asyncFactory = AsyncOperationFactory(maybeDataSource: some(asyncDataSource))
  let parentHeader = waitFor(asyncDataSource.fetchBlockHeaderWithHash(header.parentHash))
  com.db.persistHeaderToDbWithoutSetHeadOrScore(parentHeader)

  let vmState = createVmStateForStatelessMode(com, header, body, parentHeader, asyncFactory).get

  let r = processTransactions(vmState, header, @[tx])
  if r.isErr:
    error("error statelessly running tx", tx=tx, error=r.error)
  else:
    let elapsedTime = now() - t0
    let gasUsed = vmState.cumulativeGasUsed
    info("finished statelessly running the tx", elapsedTime=elapsedTime, gasUsed=gasUsed)
