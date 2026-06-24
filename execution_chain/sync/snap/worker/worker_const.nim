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
    SnapDownloadFinish             ## Wait for sync before proceeding
    SnapMkTrie                     ## Assembling downloaded data
    SnapAnalyse                    ## Analyse for missing MPT nodes
    SnapHealing                    ## Complete missing trie nodes
    SnapHealingFinish              ## Wait for sync before proceeding
    SnapContracts                  ## Download contracts code
    SnapContractsFinish            ## Wait for sync before proceeding
    SnapStop                       ## TBD ...

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

  daemonWaitReadyInterval* = chronos.seconds(30)
    ## Some polling interval time waiting until the system gets into download
    ## state when the the FCU modue hash  a finalised header.

  daemonWaitHeaderInterval* = chronos.seconds(30)
    ## Ditto for header download.

  daemonWaitElseInterval* = chronos.seconds(10)
    ## Ditto for other states.

  peerWaitElseInterval* = chronos.milliseconds(1200)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for non-`SnapDownload` states.

  threadLogTimeLimit* = chronos.seconds(45)
    ## Print intermediate messages when running a time consuming task

  threadSwitchRunLimit* = chronos.seconds(25)
    ## Force a thread switch after that time running continuously. This
    ## applies mainly for DB building and analysing sessions.

  accuAccountsCovMin* = 1.01
    ## In absence of a completed pivot state, the syncer will stop downloading
    ## if all accounts are covered at least by this factor. Then trie-assembly
    ## and healing can take place.

  stateIdleTimeBeforeEviction* = chronos.minutes(30)
    ## Minimum time a state is cached before eviction unless other criteria
    ## apply (e.g. fully unprocessed account range.)

  # ----------------------

  unprocAccountsRangeMax* = (1.u256 shl 240) # ~65k intervals
    ## Soft bytes limit to request accounts. This is used for parallelisation
    ## so that different peers can start with different intervals. Typically,
    ## these intervals are sparsely filled and there will be returned not
    ## more than ~1k accounts.

  stateDbCapacity* = 8
    ## Maximal numbers of simultanously incomplete states. Note that the
    ## protocol suggests a single peer to provide a download window of 128
    ## state roots corresponding to consecutibe block numbers.
    ##
    ## Note that there are about 400k accounts on `mainnet` (as of early 2026.)

  daemonWaitDownloadInterval* = chronos.seconds(10)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for `SnapDownload` state.

  daemonWaitDownloadFinishInterval* = chronos.seconds(5)
    ## Poll waiting for all downloading peers to have stopped

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

  fetchAccountSnapBytesLimit* = 512 * 1024
    ## Soft bytes limit to request accounts

  nProcAccountErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold` but for the later part
    ## when errors occur while cached data packets are processed.

  # -----------

  fetchStorageSnapTimeout* = chronos.seconds(120)
    ## Similar to `fetchAccountSnapTimeout`

  nFetchStorageSnapErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold`

  fetchStorageSnapBytesLimit* = 512 * 1024
    ## Similar to `fetchAccountSnapBytesLimit`

  nProcStorageErrThreshold* = 4
    ## Similar to `nProcAccountErrThreshold`

  nFetchStorageSlotsMax* = 1024
    ## Maximal size of storage slots downloaded in a single message.

  # -----------

  daemonWaitHealingInterval* = chronos.seconds(10)
    ## Poll waiting for peers to process account and storage nodes

  daemonWaitHealingFinishInterval* = chronos.seconds(5)
    ## Wait for sync

  trieNodeAccPathCapacity* = 10

  fetchTrieNodeSnapTimeout* = chronos.seconds(120)
    ## Similar to `fetchAccountSnapTimeout`

  nFetchTrieNodeSnapErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold`

  fetchTrieNodeSnapBytesLimit* = 512 * 1024
    ## Similar to `fetchAccountSnapBytesLimit`

  nProcTrieNodeErrThreshold* = 4
    ## Similar to `nProcAccountErrThreshold`

  nFetchTrieNodeSnapItemsMax* = 1024
    ## Maximal size of storage slots downloaded in a single message.

  # -----------

  daemonWaitCodesInterval* = chronos.seconds(10)
    ## Poll waiting for peers to process contract codes

  daemonWaitCodesFinishInterval* = chronos.seconds(5)
    ## Wait for sync

  fetchCodesSnapTimeout* = chronos.seconds(120)
    ## Similar to `fetchAccountSnapTimeout`

  nFetchCodesSnapErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold`

  fetchCodesSnapBytesLimit* = 512 * 1024
    ## Similar to `fetchAccountSnapBytesLimit`

  nProcCodesErrThreshold* = 4
    ## Similar to `nProcAccountErrThreshold`

  nFetchByteCodesMax* = 128
    ## Maximal sise of byte codes downloaded in a single message. Note
    ## that the snap/1 protocol description recommends someting about
    ## 80-100 items for a 515K byte limit.

# End
