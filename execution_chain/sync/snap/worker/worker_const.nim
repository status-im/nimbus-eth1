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
    SnapReady                      ## Wait for download state
    SnapDownload                   ## Downloading and caching data
    SnapMkTrie                     ## Assembling downloaded data
    SnapHealing                    ## Complete missing trie nodes

  ErrorType* = enum
    ## For `FetchError` return code object/tuple
    EGeneric = 0                   ## Not further specified error
    ENoDataAvailable               ## Out of scope, unsuuported state
    EMissingEthContext             ## Cannot retrieve `eth` peer descriptor
    EAlreadyTriedAndFailed         ## The same action failed before
    EPeerDisconnected              ## Exception
    ECatchableError                ## Exception
    ECancelledError                ## Exception
    ELockError                     ## Locked by some other peer
    ETrieError                     ## Trie/mpt database error
    ECacheError                    ## Database cache error
    ECompleted                     ## Nothing to do, here

const
  snapAsmFolder* = "snap"
    ## Folder for assembly database (different from aristo `ecdb` folder)

  twoHundredYears* = chronos.days(365 * 200 + 48)
    ## Large Duration constant considered sort of infinite.

  daemonWaitReadyInterval* = chronos.seconds(20)
    ## Some polling interval time waiting until the system gets into download
    ## state when the the FCU modue hash  a finalised header.

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

  lockWaitPollingTime* = chronos.milliseconds(500)
    ## Polling for a lock to be released

  accuAccountsCovMin* = 2.0
    ## In absence of a completed pivot state, the syncer will stop downloading
    ## if all accounts are covered at least by this factor. Then trie-assembly
    ## and healing can take place if the pivot state is also sufficiently
    ## covered (see  `accuPivotCovMin` below.)
    ##
    ## The reasoning for getting away without a completed pivot is that state
    ## changes between consecutive trie states are small. There is a fair
    ## chance that the pivot state will also have valid accounts identical
    ## with other states.

  accuPivotCovMin* = 0.7
    ## If the total coverage has reached the factor `accuAccountsCovMin`, the
    ## pivot must also have reached the factor `accuPivotCovMin` in order to
    ## start trie assembly and healing.

  relativeCoverageEvictionThreshold* = 0.1
    ## If the ratio
    ## ::
    ##   minimal-state-coverage / pivot-acccounts-coverage
    ##
    ## is not small enough, then the pivot state may be evicted from the
    ## states list to make space for a new state.

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

  nFetchHeaderPeersMax* = 5
    ## Try at most this many `eth` peers for fetching a header

  fetchHeaderRlpxTimeout* = chronos.seconds(30)
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

  nFetchStorageSlotsMax* = 1024
    ## Maximal size of storage slots downloaded in a single message.

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
