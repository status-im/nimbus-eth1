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
    SnapResume                     ## Resume from previous session
    SnapClear                      ## Reset and prepare for brand new start
    SnapReady                      ## Wait for download state
    SnapDownload                   ## Download and cache initial state data
    SnapDownloadFinish             ## Wait for sync before proceeding
    SnapDownloadCommit             ## Get ready for BAL forward
    SnapBalsFetch                  ## Bring state forward using BALs
    SnapBalsFetchFinish            ## Wait for sync before proceeding
    SnapStateForward               ## Apply BALs and advance state
    SnapStop                       ## End of snap sync

  ErrorType* = enum
    ## For `FetchError` return code object/tuple
    EGeneric = 0                   ## Not further specified error
    EAlreadyTriedAndFailed         ## The same action failed before
    EMissingEthContext             ## Cannot retrieve `eth` peer descriptor
    EPeerDisconnected              ## Exception
    ECatchableError                ## Exception
    ECancelledError                ## Exception

    # The following symbols are not used in fetch functions (see below
    # the symbol set `EUnusedForFetch`.)
    ENoDataAvailable               ## Out of scope, unsuuported state
    ELockError                     ## Locked by some other peer
    EDirtyData                     ## Some data must be cleaned up. first
    EMergeError                    ## MPT builder error
    EFinalisationError             ## MPT builder error
    EValidationError               ## Sub-MPT validation failed
    ECacheError                    ## Database cache error
    ECompleted                     ## Nothing to do, here
    ERlpError                      ## Decoding problem
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

  threadSwitchTimeSlot* = chronos.milliseconds(300)
    ## For some long running jobs, a pseudo thread switch is forced using
    ## nano-seep wait. This is the time between wto of these nano-seep
    ## directives.

  # -----------------

  noPeersLogWaitInterval* = chronos.seconds(50)
    ## Reduce logging noise

  noHeadersLogWaitInterval* = chronos.seconds(120)
    ## Reduce logging noise

  triggeredHeadersLogWaitInterval* = chronos.seconds(120)
    ## Reduce logging noise

  maxHeadersLogWaitInterval* = chronos.seconds(30)
    ## Reduce logging noise

  beaconSyncIdleLogWaitInterval* = chronos.seconds(10)
    ## Reduce logging noise

  noBalSupportLogWaitInterval* = chronos.seconds(30)
    ## Reduce logging noise

  # ---------

  daemonWaitClearFailInterval* = chronos.seconds(10)
    ## Something failed in `SnapClear` state, e.g. starting header
    ## download (just avoiding some extra polling.)

  daemonWaitReadyDwnldFailInterval* = chronos.seconds(15)
    ## Header download trigger failed

  daemonWaitReadyInitFailInterval* = chronos.seconds(5)
    ## Snap download init failed. System is not ready yet.

  daemonWaitDownloadInterval* = chronos.seconds(1)
    ## Poll waiting for peers downloading snap data. The polling cycle also
    ## triggers some metrics updates.

  daemonWaitBalsFetchInterval* = chronos.seconds(1)
    ## Poll waiting for some peer to download BALs

  daemonWaitHeaderStopInterval* = chronos.seconds(5)
    ## Poll waiting for some peer to download BALs

  # ---------

  peerWaitDownloadInterval* = chronos.seconds(5)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for non-`SnapDownload` states.

  peerWaitElseInterval* = chronos.milliseconds(1200)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background. This one is for non-`SnapDownload` states.

  peerWaitExhaustedInterval* = chronos.milliseconds(1200)
    ## Suspend peer until the download state has been forwarded. This timeout
    ## will be regularly polled for the updated state.

  peerWaitBalsSnap1Interval* = chronos.milliseconds(300)
    ## Suspend snap/1 peer for BALs download emulation when snap/2 peers
    ## are available.

  peerWaitBalsNoDataInterval* = chronos.milliseconds(300)
    ## Suspend  peer for BALs download if there were no available.

  peerWaitBalsLockedInterval* = chronos.milliseconds(300)
    ## Only one peer can download BALs. This constatnt is the polling timr
    ## for the waiting peers.

  peerWaitHeadersInterval* = chronos.milliseconds(300)
    ## Suspend peer waiting for new headers. Then check again.

  peerWaitNoEthPeersInterval* = chronos.milliseconds(500)
    ## Waithing for eth peers supporting BAL

  # ----------------------

  unprocAccountsRangeMax* = (1.u256 shl 244) # 2^12: ~4k different ranges
    ## Maximal range of accounts to request in a single message. This is
    ## used for parallelisation, so that different peers can request
    ## different ranges. The implied number of ranges should not be be
    ## significantly lower than 100 so that it works with 50 or somewhat
    ## more peers.
    ##
    ## Larger ranges have the advantage to download more accounts within a
    ## single response packet. Many accounts records have not maximal size,
    ## so it is possible to pack 16k accounts with 32 bytes average size in
    ## a 500k message if the range is large enough.

  nConsecutiveAccountRefreshMax* = 200
    ## After BAL update, some accounts are needed to be re-fetched in order
    ## to fetch the hash keys for fetching missing storage slots or contract
    ## codes. These accounts are typically isolated and updated as as a single
    ## entity. If the account downloader proceeded with storage slots after
    ## each refreshed account, the storage downloader would have a single
    ## sub-MPT to fetch, only. So the storage downloader will not be called
    ## until several (i.e. this constant) accounts are refreshed in a row
    ## first.
    ##
    ## This constant must be small enough so that there is a chance that
    ## all accounts can be refreshed in a short time (i.e. download window)
    ## to avoid getting stuck with accounts downloading, only.

  nStateDownloadWindowSize* = 128
    ## This value is for metrics/logging only. The effective state download
    ## window is stated below.

  nFinHeadSupportWindowSize* = 57                   # ~45% of 128
    ## If the FCU finalised header is more than that distance apart from
    ## the pivot state block number, a BAL download and forward cycle will
    ## be triggerd. The download window ranges
    ## ::
    ##    finalised-head - nFinHeadSupportWindowSize .. finalised-head
    ##
    ## Providing a shorter interval than 128 will stop starting new download
    ## sessions while running current downloading sessions until the peers
    ## stop replying or there is no more work left.

  nFinHeadSupportWindowTopMargin* = 40
    ## Top (or right end) acceptance margin for the download window. The
    ## state of the partial MPT representation is forwarded until it falls
    ## in the range
    ## ::
    ##    finalised-head - nFinHeadSupportWindowTopMargin .. finalised-head
    ##
    ## (providing a hysteresis.)

  # -----------

  fetchAccountSnapTimeout* = chronos.seconds(120)
    ## Timeout cap for the `RLPX` handler when fetching accounts.

  nFetchAccountSnapErrThreshold* = 4
    ## Maximum account fetch errors before zombification.

  fetchAccountSnapBytesLimit* = 1024 * 1024
    ## Soft bytes limit to request accounts.

  nProcAccountErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold` but for the later part
    ## when errors occur while cached data packets are processed.

  # -----------

  fetchStorageBatchMax* = 2 * 1024
    ## Maximal batch size for storage slots.

  fetchStorageSnapTimeout* = chronos.seconds(120)
    ## Similar to `fetchAccountSnapTimeout`

  nFetchStorageSnapErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold`

  fetchStorageSnapBytesLimit* = 1024 * 1024
    ## Similar to `fetchAccountSnapBytesLimit`

  nProcStorageErrThreshold* = 4
    ## Similar to `nProcAccountErrThreshold`

  # -----------

  fetchCodeBatchMax* = 2 * 1024
    ## Maximal batch size for contract codes.

  fetchCodesSnapTimeout* = chronos.seconds(120)
    ## Similar to `fetchAccountSnapTimeout`

  nFetchCodesSnapErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold`

  fetchCodesSnapBytesLimit* = 1024 * 1024
    ## Similar to `fetchAccountSnapBytesLimit`

  nProcCodesErrThreshold* = 4
    ## Similar to `nProcAccountErrThreshold`

  # -----------

  ethFetchBalCapacity* = 10
    ## Register first hash of last BAL request for error handling
    ## support.

  nFetchBalEthPeersMax* = 5
    ## Try at most this many `eth` peers for fetchinga block access lists.

  nFetchBalSnapSizeMax* = 2 * 1024 * 1024
    ## Maximal response size for a BAL request

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

  # -----------

  nBacklogHeaders* = 256
    ## Number of headers and block hashes to provide preceeding the final
    ## pivot state so that the `BLOCKHASH` evm code can succeed.

  # -----------

  nCoreDbImportPersistBatch* = 384 * 1024
    ## When importing accounts, storage, and contract codes the caches are
    ## regularly saved to disk after this many items have benn processed.
    ## This constant defines a memory/time trade off. The lower the value,
    ## the less memory is used.

  coreDbImportMsgInterval* = chronos.seconds(40)
    ## Some status noise messages from time to time

# End
