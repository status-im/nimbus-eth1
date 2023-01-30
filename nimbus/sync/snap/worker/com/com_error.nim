# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  chronos,
  ../../../sync_desc,
  ../../constants

{.push raises: [].}

type
  ComErrorStatsRef* = ref object
    ## particular error counters so connections will not be cut immediately
    ## after a particular error.
    nTimeouts*: uint
    nNoData*: uint
    nNetwork*: uint

  ComError* = enum
    ComNothingSerious
    ComAccountsMaxTooLarge
    ComAccountsMinTooSmall
    ComEmptyAccountsArguments
    ComEmptyPartialRange
    ComEmptyRequestArguments
    ComNetworkProblem
    ComNoAccountsForStateRoot
    ComNoByteCodesAvailable
    ComNoHeaderAvailable
    ComNoStorageForAccounts
    ComNoTrieNodesAvailable
    ComResponseTimeout
    ComTooManyByteCodes
    ComTooManyHeaders
    ComTooManyStorageSlots
    ComTooManyTrieNodes


proc resetComError*(stats: ComErrorStatsRef) =
  ## Reset error counts after successful network operation
  stats[].reset

proc stopAfterSeriousComError*(
    ctrl: BuddyCtrlRef;
    error: ComError;
    stats: ComErrorStatsRef;
      ): Future[bool]
      {.async.} =
  ## Error handling after data protocol failed. Returns `true` if the current
  ## worker should be terminated as *zombie*.
  case error:
  of ComResponseTimeout:
    stats.nTimeouts.inc
    if comErrorsTimeoutMax < stats.nTimeouts:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      ctrl.zombie = true
      return true

    when 0 < comErrorsTimeoutSleepMSecs:
      # Otherwise try again some time later.
      await sleepAsync(comErrorsTimeoutSleepMSecs.milliseconds)

  of ComNetworkProblem:
    stats.nNetwork.inc
    if comErrorsNetworkMax < stats.nNetwork:
      ctrl.zombie = true
      return true

    when 0 < comErrorsNetworkSleepMSecs:
      # Otherwise try again some time later.
      await sleepAsync(comErrorsNetworkSleepMSecs.milliseconds)

  of ComNoAccountsForStateRoot,
     ComNoByteCodesAvailable,
     ComNoStorageForAccounts,
     ComNoHeaderAvailable,
     ComNoTrieNodesAvailable:
    stats.nNoData.inc
    if comErrorsNoDataMax < stats.nNoData:
      ctrl.zombie = true
      return true

    when 0 < comErrorsNoDataSleepMSecs:
      # Otherwise try again some time later.
      await sleepAsync(comErrorsNoDataSleepMSecs.milliseconds)

  of ComAccountsMinTooSmall,
     ComAccountsMaxTooLarge,
     ComTooManyByteCodes,
     ComTooManyHeaders,
     ComTooManyStorageSlots,
     ComTooManyTrieNodes:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    ctrl.zombie = true
    return true

  of ComEmptyAccountsArguments,
     ComEmptyRequestArguments,
     ComEmptyPartialRange,
     ComNothingSerious:
    discard

# End
