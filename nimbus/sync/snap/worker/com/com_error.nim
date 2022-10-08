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
  ../../../sync_desc

const
  comErrorsTimeoutMax* = 2
    ## Maximal number of non-resonses accepted in a row. If there are more than
    ## `comErrorsTimeoutMax` consecutive errors, the worker will be degraded
    ## as zombie.

type
  ComErrorStatsRef* = ref object
    ## particular error counters so connections will not be cut immediately
    ## after a particular error.
    nTimeouts*: uint
    nNetwork*: uint

  ComError* = enum
    ComNothingSerious
    ComAccountsMaxTooLarge
    ComAccountsMinTooSmall
    ComEmptyAccountsArguments
    ComEmptyRequestArguments
    ComMissingProof
    ComNetworkProblem
    ComNoAccountsForStateRoot
    ComNoByteCodesAvailable
    ComNoDataForProof
    ComNoHeaderAvailable
    ComNoStorageForAccounts
    ComNoTrieNodesAvailable
    ComResponseTimeout
    ComTooManyByteCodes
    ComTooManyHeaders
    ComTooManyStorageSlots
    ComTooManyTrieNodes

    # Other errors not directly related to communication
    ComInspectDbFailed
    ComImportAccountsFailed


proc stopAfterSeriousComError*(
    ctrl: BuddyCtrlRef;
    error: ComError;
    stats: ComErrorStatsRef;
      ): Future[bool]
      {.async.} =
  ## Error handling after data protocol failed.
  case error:
  of ComResponseTimeout:
    stats.nTimeouts.inc
    if comErrorsTimeoutMax < stats.nTimeouts:
      # Mark this peer dead, i.e. avoid fetching from this peer for a while
      ctrl.zombie = true
    else:
      # Otherwise try again some time later. Nevertheless, stop the
      # current action.
      await sleepAsync(5.seconds)
    return true

  of ComNetworkProblem,
     ComMissingProof,
     ComAccountsMinTooSmall,
     ComAccountsMaxTooLarge:
    stats.nNetwork.inc
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    ctrl.zombie = true
    return true

  of ComEmptyAccountsArguments,
     ComEmptyRequestArguments,
     ComInspectDbFailed,
     ComImportAccountsFailed,
     ComNoDataForProof,
     ComNothingSerious:
    discard

  of ComNoAccountsForStateRoot,
     ComNoStorageForAccounts,
     ComNoByteCodesAvailable,
     ComNoHeaderAvailable,
     ComNoTrieNodesAvailable,
     ComTooManyByteCodes,
     ComTooManyHeaders,
     ComTooManyStorageSlots,
     ComTooManyTrieNodes:
    # Mark this peer dead, i.e. avoid fetching from this peer for a while
    ctrl.zombie = true
    return true

# End
