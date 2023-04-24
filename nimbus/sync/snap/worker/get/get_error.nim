# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronos,
  ../../../sync_desc,
  ../../constants

type
  GetErrorStatsRef* = ref object
    ## particular error counters so connections will not be cut immediately
    ## after a particular error.
    peerDegraded*: bool
    nTimeouts*: uint
    nNoData*: uint
    nNetwork*: uint

  GetError* = enum
    GetNothingSerious
    GetAccountsMaxTooLarge
    GetAccountsMinTooSmall
    GetEmptyAccountsArguments
    GetEmptyPartialRange
    GetEmptyRequestArguments
    GetNetworkProblem
    GetNoAccountsForStateRoot
    GetNoByteCodesAvailable
    GetNoHeaderAvailable
    GetNoStorageForAccounts
    GetNoTrieNodesAvailable
    GetResponseTimeout
    GetTooManyByteCodes
    GetTooManyHeaders
    GetTooManyStorageSlots
    GetTooManyTrieNodes


proc getErrorReset*(stats: GetErrorStatsRef) =
  ## Reset error counts after successful network operation
  stats[].reset

proc getErrorStopAfterSeriousOne*(
    ctrl: BuddyCtrlRef;
    error: GetError;
    stats: GetErrorStatsRef;
      ): Future[bool]
      {.async.} =
  ## Error handling after data protocol failed. Returns `true` if the current
  ## worker should be terminated as *zombie*.
  case error:
  of GetResponseTimeout:
    stats.nTimeouts.inc
    if comErrorsTimeoutMax < stats.nTimeouts:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      ctrl.zombie = true
      stats.peerDegraded = true
      return true

    when 0 < comErrorsTimeoutSleepMSecs:
      # Otherwise try again some time later.
      await sleepAsync(comErrorsTimeoutSleepMSecs.milliseconds)

  of GetNetworkProblem:
    stats.nNetwork.inc
    if comErrorsNetworkMax < stats.nNetwork:
      ctrl.zombie = true
      stats.peerDegraded = true
      return true

    when 0 < comErrorsNetworkSleepMSecs:
      # Otherwise try again some time later.
      await sleepAsync(comErrorsNetworkSleepMSecs.milliseconds)

  of GetNoAccountsForStateRoot,
     GetNoByteCodesAvailable,
     GetNoStorageForAccounts,
     GetNoHeaderAvailable,
     GetNoTrieNodesAvailable:
    stats.nNoData.inc
    if comErrorsNoDataMax < stats.nNoData:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      ctrl.zombie = true
      return true

    when 0 < comErrorsNoDataSleepMSecs:
      # Otherwise try again some time later.
      await sleepAsync(comErrorsNoDataSleepMSecs.milliseconds)

  of GetAccountsMinTooSmall,
     GetAccountsMaxTooLarge,
     GetTooManyByteCodes,
     GetTooManyHeaders,
     GetTooManyStorageSlots,
     GetTooManyTrieNodes:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    ctrl.zombie = true
    return true

  of GetEmptyAccountsArguments,
     GetEmptyRequestArguments,
     GetEmptyPartialRange,
     GetError(0):
    discard

# End
