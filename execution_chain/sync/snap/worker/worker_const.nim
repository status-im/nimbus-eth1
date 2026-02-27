# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronos, stint]

type
  SyncState* = enum
    SnapIdle = 0
    SnapResume                     ## Resume from previous session
    SnapDownload                   ## Downloading and caching data
    SnapMkTrie                     ## Assembling downloaded data
    SnapHealing                    ## Complete missing trie nodes

  ErrorType* = enum
    ## For `FetchError` return code object/tuple
    EGeneric = 0                   ## Not further specified error
    ENoDataAvailable               ## Out of scope
    EMissingEthContext             ## Cannot retrieve `eth` peer descriptor
    EAlreadyTriedAndFailed         ## The same action failed before
    EPeerDisconnected              ## Exception
    ECatchableError                ## Exception
    ECancelledError                ## Exception

const
  snapAsmFolder* = "snap"
    ## Folder for assembly database (different from aristo `ecdb` folder)

  twoHundredYears* = chronos.days(365 * 200 + 48)
    ## Large Duration constant considered sort of infinite.

  daemonWaitDownloadInterval* = chronos.seconds(10)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for `SnapDownload` state.

  daemonWaitElseInterval* = chronos.seconds(10)
    ## Ditto for other states than `SnapMkTrie` or `SnapHealing`.

  peerWaitElseInterval* = chronos.milliseconds(1200)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for non-`SnapDownload` states.

  mktrieThreadSwitchTimeSlot* = chronos.nanoseconds(1)
    ## Nano-sleep to allows pseudo/async thread switch

  # ----------------------

  unprocAccountsRangeMax* = (1.u256 shl 240) # ~65k intervals
    ## Soft bytes limit to request accounts. This is used for parallelisation
    ## so that different peers can start with different intervals. Typically,
    ## these intervals are sparsely filled and there will be returned not
    ## more than  ~1k accounts.

  stateDbCapacity* = 8
    ## Maximal numbers of simultanously incomplete states. Note that the
    ## protocol suggests a single peer to provide a download window of 128
    ## state roots corresponding to consecutibe block numbers.
    ##
    ## Note that there are about 400k accounts on `mainnet` (as of early 2026.)

  nWorkingStateRootsMax* = 3
    ## Stop the current session after accounts could be downloaded for this
    ## many different state roots. The session will then be released and a
    ## new one started.

  # -----------

  fetchHeadersRlpxTimeout* = chronos.seconds(30)
    ## Timeout cap for the `RLPX` handler when fetching header. This value

  # -----------

  fetchAccountSnapTimeout* = chronos.seconds(120)
    ## Timeout cap for the `RLPX` handler when fetching accounts.

  nFetchAccountSnapErrThreshold* = 4
    ## Maximum account fetch errors before zombification.

  fetchAccountSnapBytesLimit* = 50 * 1024
    ## Soft bytes limit to request accounts

  nProcAccountErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold` but for the later part
    ## when errors occur while cached data packets are processed.

  # -----------

  fetchStorageSnapTimeout* = chronos.seconds(120)
    ## Similar to `fetchAccountSnapTimeout`

  nFetchStorageSnapErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold`

  fetchStorageSnapBytesLimit* = 50 * 1024
    ## Similar to `fetchAccountSnapBytesLimit`

  nProcStorageErrThreshold* = 4
    ## Similar to `nProcAccountErrThreshold`

  # -----------

  fetchCodesSnapTimeout* = chronos.seconds(120)
    ## Similar to `fetchAccountSnapTimeout`

  nFetchCodesSnapErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold`

  fetchCodesSnapBytesLimit* = 50 * 1024
    ## Similar to `fetchAccountSnapBytesLimit`

  nProcCodesErrThreshold* = 4
    ## Similar to `nProcAccountErrThreshold`

# End
