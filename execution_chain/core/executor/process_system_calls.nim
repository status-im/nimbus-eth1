# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  ../../common/common,
  ../../db/ledger,
  ../../evm/state,
  ../../evm/types,
  ../../block_access_list/bal_tracker,
  ../dao,
  ./process_transaction,
  results

export results

type BlockRequests* = object
  withdrawalReqs*: seq[byte]
  consolidationReqs*: seq[byte]
  builderDepositReqs*: seq[byte]
  builderExitReqs*: seq[byte]

proc processPreExecSystemCalls*(
    vmState: BaseVMState, header: Header, persist = true
) =
  ## Applies the state changes which happen before the block transactions are
  ## executed. These changes are recorded at block access index zero in the
  ## block access list.
  ##
  ## The header fields read here are validated by the caller before calling
  ## this procedure. When `persist` is false the changes are only applied to
  ## the ledger caches and never written to the underlying txFrame which is
  ## required when running this as a task during parallel block execution.
  let com = vmState.com

  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(0)
    vmState.balTracker.beginCallFrame()

  vmState.mutateLedger:
    if com.daoForkSupport and com.daoForkBlock.get == header.number:
      ledger.applyDAOHardFork()

  if com.isPragueOrLater(header.timestamp):
    vmState.processParentBlockHash(header.parentHash, persist)

  if com.isCancunOrLater(header.timestamp):
    vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.value, persist)

  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

proc processPostExecSystemCalls*(
    vmState: BaseVMState, blk: Block, persist = true
): Result[BlockRequests, string] =
  ## Applies the withdrawals and the state changes which happen after the block
  ## transactions are executed. These changes are recorded at block access index
  ## `transactions.len + 1` in the block access list.
  ##
  ## The header and body fields read here are validated by the caller before
  ## calling this procedure. When `persist` is false the changes are only
  ## applied to the ledger caches and never written to the underlying txFrame
  ## which is required when running this as a task during parallel block
  ## execution.
  template header(): Header =
    blk.header

  let com = vmState.com

  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(blk.transactions.len() + 1)
    vmState.balTracker.beginCallFrame()

  if com.isShanghaiOrLater(header.timestamp):
    if vmState.balTrackerEnabled:
      for withdrawal in blk.withdrawals.get:
        vmState.balTracker.trackAddBalanceChange(withdrawal.address, withdrawal.weiAmount)
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)
    else:
      for withdrawal in blk.withdrawals.get:
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)

  var requests: BlockRequests

  if header.requestsHash.isSome:
    # Execute EIP-7002 and EIP-7251 before calculating stateRoot
    # because they will alter the state
    requests.withdrawalReqs = ?processDequeueWithdrawalRequests(vmState, persist)
    requests.consolidationReqs = ?processDequeueConsolidationRequests(vmState, persist)

    if com.isAmsterdamOrLater(header.timestamp):
      requests.builderDepositReqs = ?processBuilderDepositRequests(vmState, persist)
      requests.builderExitReqs = ?processBuilderExitRequests(vmState, persist)

  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  if persist:
    vmState.ledger.persist(
      clearEmptyAccount = com.isSpuriousOrLater(header.number, header.timestamp))

  ok(requests)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
