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
  SnapState* = enum
    SnapIdle = 0
    SnapReady                      ## Wait for download state
    SnapResume                     ## Resume from previous session
    SnapDownload                   ## Downloading and caching data
    SnapDownloadFinish             ## Wait for sync before proceeding
    # ..                           ## TBD ..
    SnapStop                       ## TBD ..

  ErrorType* = enum
    ## For `FetchError` return code object/tuple
    EGeneric = 0                   ## Not further specified error
    EAlreadyTriedAndFailed         ## The same action failed before
    EPeerDisconnected              ## Exception
    ECatchableError                ## Exception
    ECancelledError                ## Exception

    # The following symbols are not used in fetch functions (see below
    # the symbol set `EUnusedForFetch`.)
    ENoDataAvailable               ## Out of scope, unsuuported state
    EMissingEthContext             ## Cannot retrieve `eth` peer descriptor
    ELockError                     ## Locked by some other peer
    ETrieError                     ## Trie/mpt database error
    ECacheError                    ## Database cache error
    ECompleted                     ## Nothing to do, here
    EArgumentError                 ## Inconsistent function arguments
    EMissingBalSupport             ## Chain before `Amsterdam`
    EHeadersMissing                ## Need to fetch more headers

const
  EUnusedForFetch* = {ENoDataAvailable .. EHeadersMissing}
    ## Shortcut for `case..of` directive. These error symbols are not used
    ## for fetching data via the `snap` or `eth` wire protocol.

  # -----------------

  snapAsmFolder* = "snap"
    ## Folder for assembly database (different from aristo `ecdb` folder)

  twoHundredYears* = chronos.days(365 * 200 + 48)
    ## Large Duration constant considered sort of infinite.

  daemonWaitReadyInterval* = chronos.seconds(47)
    ## Some polling interval time waiting until the system gets into download
    ## state when the the FCU modue hash provides a finalised header and there
    ## are eth/xx download peers available.

  daemonWaitElseInterval* = chronos.seconds(10)
    ## Ditto for other states.

  peerWaitDownloadInterval* = chronos.seconds(5)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for non-`SnapDownload` states.

  peerWaitElseInterval* = chronos.milliseconds(1200)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for non-`SnapDownload` states.

  # ----------------------

  unprocAccountsRangeMax* = (1.u256 shl 240) # ~65k intervals
    ## Soft bytes limit to request accounts. This is used for parallelisation
    ## so that different peers can start with different intervals. Typically,
    ## these intervals are sparsely filled and there will be returned not
    ## more than ~1k accounts.

  # -----------

  nConsHeadcachedDeltaMax* = 128
    ## If the block number difference between FCU update header and cached
    ## header is larger than this contant, a beacon header fetch cycle is
    ## triggered to fill up the cache.

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

  # -----------

  ethBalFetchCapacity* = 10
    ## Register first hash of last BAL request for error handling
    ## support.

  nFetchBalEthPeersMax* = 5
    ## Try at most this many `eth` peers for fetchinga block access lists.

  fetchBalRlpxTimeout* = chronos.seconds(50)
    ## Timeout cap for the `RLPx` handlers, either `snap` or `eth`
    ## when fetching block access lists.

  fetchBalErrTimeout* = chronos.seconds(25)
    ## Needed for detecting slow peers. If the response time exceeds this
    ## threshold, the peer is considered `slow`.

  nFetchBalErrThreshold* = 4
    ## Maximum account fetch errors before zombification.

  nProcBalErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold` but for the later part
    ## when errors occur while cached data packets are processed.

  nProcBalDwnldBatchMax* = 800
    ## Maximal size of single download batch for BALs.

  nProcBalDefaultChunk* = 80
    ## Default size for auto downloading a single chunk of BALs.

  nProcBalDefaultBatchMax* = 1000
    ## Default maximum number of BALs for a single auto downloading session.

# End
