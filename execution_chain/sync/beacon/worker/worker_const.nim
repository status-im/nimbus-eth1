# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/chronos

type
  SyncState* = enum
    idle = 0                       ## see clause *(8)*, *(12)* of `README.md`
    headers                        ## see clauses *(5)*, *(9)* of `README.md`
    headersCancel                  ## stop this scrum
    headersFinish                  ## see clause *(10)* of `README.md`
    blocks                         ## see clause *(11)* of `README.md`
    blocksCancel                   ## stop this syncer scrum
    blocksFinish                   ## get ready for `idle`

  DownloadPerformance* = enum
    rankingTooLow = 0              ## Lower mean throughput than others
    rankingOk                      ## Better mean throughput than some others
    notEnoughData                  ## Not enough data to assess
    qSlotsAvail                    ## No assessment needed (e.g. few peers)
    notApplicable                  ## Not useful here

  BeaconErrorType* = enum
    ## For `FetchError` return code object/tuple
    ENoException = 0
    ESyncerTermination             ## Syncer was stopped
    EAlreadyTriedAndFailed         ## The same action failed before
    EPeerDisconnected              ## Exception
    ECatchableError                ## Exception
    ECancelledError                ## Exception

const
  twoHundredYears* = chronos.days(365 * 200 + 48)
    ## Large Duration constant considered sort of infinite.

  metricsUpdateInterval* = chronos.seconds(10)
    ## Wait at least this time before next update

  daemonWaitInterval* = chronos.seconds(10)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background.

  noPeersLogWaitInterval* = chronos.seconds(50)
    ## Control missing peers messages issued from time to time (if any.)

  syncUpdateLogWaitInterval* = chronos.seconds(30)
    ## Control log chatter for update messages

  workerIdleWaitInterval* = chronos.seconds(1)
  workerIdleLongWaitInterval* = chronos.seconds(5)
    ## Sleep some time in multi-mode (i.e. concurrently running peers) if
    ## there is nothing else to do

  asyncThreadSwitchTimeSlot* = chronos.nanoseconds(1)
    ## Nano-sleep to allows pseudo/async thread switch

  asyncThreadSwitchGap* = chronos.milliseconds(300)
    ## Controls nano-sleep tart switch density when using this in a loop (e.g.
    ## for processing lists.) The constant requires a minimum time gap when
    ## invoking a nano-sleep utility.

  # ----------------------

  nFetchTargetFailedPeersThreshold* = 7
    ## Similar to `nFetchHeadersFailedInitialPeersThreshold` below for
    ## fetching the first syncer target by means of a given hash.

  # ----------------------

  nFetchHeadersFailedInitialPeersThreshold* = 30
    ## If there are more failing peers than this threshold right at the
    ## begining of a header chain download scrum (before any data received),
    ## then this session (scrum or sprint) is discarded and the syncer is
    ## reset and suspened (waiting for the next activation to restart a new
    ## session.)

  nFetchHeadersRequest* = 800
    ## Number of headers that will be requested with a single `eth/xx` message.
    ##
    ## On `Geth`, responses to larger requests are all truncted to 1024 header
    ## entries (see `Geth` constant `maxHeadersServe`.)

  fetchHeadersRlpxTimeout* = chronos.seconds(50)
    ## Timeout cap for the `RLPX` handler when fetching header. This value
    ## should pretty large so that even in case that the peer is delaying
    ## (typically due to downloading from here), there will be a valid data
    ## response in many cases.
    ##
    ## The system calculates the elapsed time which covers request, response,
    ## and some kind of actions in-between including some peer download
    ## data provided by this system.
    ##
    ## The elapsed time is then used to assess a peer so that low performing
    ## peers (over the network) can be assigned `slow` (meant figuratively,
    ## not literally `slow`, but nevertheless leading to long download delays.)

  fetchHeadersErrTimeout* = chronos.seconds(25)
  nFetchHeadersErrThreshold* = 4
    ## Response time allowance (see also comment on `fetchHeadersRlpxTimeout`.)
    ## If the response time for the set of headers exceeds this threshold for
    ## more than `nFetchHeadersErrThreshold` times in a row, then this peer will
    ## be banned for a while.

  nProcHeadersErrThreshold* = 2
    ## Similar to `nFetchHeadersErrThreshold` but for the later part when
    ## errors occur while block headers are queued and further processed.

  nStashHeadersErrThreshold* = 2
    ## Abort headers download and the whole sync session with it if too many
    ## failed header chain cache storage requests occur.

  headersStagedQueueLengthMax* = 8
    ## If the staged header queue reaches this many queue objects for
    ## serialising and caching on disk, no further objects are added.

  # ----------------------

  nFetchBodiesFailedInitialPeersThreshold* = 50
    ## Similar to `nFetchHeadersFailedInitialPeersThreshold`.

  nFetchBodiesRequest* = 40
    ## Similar to `nFetchHeadersRequest`.

  fetchBodiesRlpxTimeout* = chronos.seconds(50)
    ## Similar to `nFetchHeadersRlpxThreshold`

  fetchBodiesErrTimeout* = chronos.seconds(25)
  nFetchBodiesErrThreshold* = 4
    ## Similar to `nFetchHeadersErrThreshold`.

  nProcBlocksErrThreshold* = 2
    ## Similar to `nProcHeadersErrThreshold`.

  nImportBlocksErrThreshold* = 2
    ## Abort block import and the whole sync session with it if too many
    ## failed imports occur into `FC` module.

  blocksStagedQueueLengthMax* = 2
    ## Similar to `headersStagedQueueLengthMax`.

  # ----------------------

static:
  doAssert 0 < nFetchHeadersRequest
  doAssert 0 < headersStagedQueueLengthMax

  doAssert 0 < nFetchBodiesRequest
  doAssert 0 < blocksStagedQueueLengthMax

# End
