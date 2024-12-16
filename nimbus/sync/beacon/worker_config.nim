# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
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

const
  enableTicker* = false
    ## Log regular status updates similar to metrics. Great for debugging.

  runsThisManyPeersOnly* = 8
    ## Set to `1` for running a single peer only at a time. Great for debugging.
    ##
    ## Otherwise, this setting limits the number of peers accepted by the
    ## `runStart()` peer initialiser. When testing with an unlimited number of
    ## peers with some double digit number of connected peers, the observed
    ## response times when fetching headers seemed to degrade considerable into
    ## seconds (rather than ms.) This will be further looked at to be confirmed
    ## or rejected as insignificant.
    ##
    ## FIXME: This setting has priority over the `maxPeers` setting of the
    ##        `BeaconSyncRef.init()` initaliser. This might be harmonised at
    ##        a later stage.

  # ----------------------

  metricsUpdateInterval* = chronos.seconds(10)
    ## Wait at least this time before next update

  daemonWaitInterval* = chronos.seconds(10)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background.

  workerIdleWaitInterval* = chronos.seconds(10)
    ## Sleep some time in multi-mode if there is nothing to do

  asyncThreadSwitchTimeSlot* = chronos.nanoseconds(1)
    ## Nano-sleep to allows pseudo/async thread switch

  # ----------------------

  nFetchHeadersRequest* = 1_024
    ## Number of headers that will be requested with a single `eth/xx` message.
    ##
    ## On `Geth`, responses to larger requests are all truncted to 1024 header
    ## entries (see `Geth` constant `maxHeadersServe`.)

  fetchHeadersReqErrThresholdZombie* = chronos.seconds(2)
  fetchHeadersReqErrThresholdCount* = 3
    ## Response time allowance. If the response time for the set of headers
    ## exceeds this threshold for more than `fetchHeadersReqThresholdCount`
    ## times in a row, then this peer will be banned for a while.

  fetchHeadersReqMinResponsePC* = 10
    ## Some peers only returned one header at a time. If these peers sit on a
    ## farm, they might collectively slow down the download process. So this
    ## constant sets a percentage of minimum headers needed to return so that
    ## the peers is not treated as a slow responder (see above for slow
    ## responder count.)

  nFetchHeadersBatch* = 8 * nFetchHeadersRequest
    ## Length of the request/stage batch. Several headers are consecutively
    ## fetched and stashed together as a single record on the staged queue.

  headersStagedQueueLengthLwm* = 32
    ## Limit the number of records in the staged headers queue.
    ##
    ## Queue entries start accumulating if one peer stalls while fetching the
    ## top chain so leaving a gap. This gap must be filled first before
    ## inserting the queue into a contiguous chain of headers.
    ##
    ## This low-water mark tryggers the system to do some **magic** to mitigate
    ## the above problem. Currently the **magic** is to let (pseudo) threads
    ## terminate and then restart all over again.

  headersStagedQueueLengthHwm* = 48
    ## If this size is exceeded, the staged queue is flushed and resized to
    ## `headersStagedQueueLengthLwm-1` entries. Then contents is re-fetched
    ## from scratch.

  # ----------------------

  nFetchBodiesRequest* = 128
    ## Similar to `nFetchHeadersRequest`

  fetchBodiesReqErrThresholdZombie* = chronos.seconds(4)
  fetchBodiesReqErrThresholdCount* = 3
    ## Similar to `fetchHeadersReqThreshold*`

  fetchBodiesReqMinResponsePC* = 10
    ## Similar to `fetchHeadersReqMinResponsePC`

  nFetchBodiesBatchDefault* = 6 * nFetchBodiesRequest
    ## Similar to `nFetchHeadersBatch`
    ##
    ## This value can be overridden with a smaller value which must be at
    ## least `nFetchBodiesRequest`.

  blocksStagedQueueLenMaxDefault* = 16
    ## Maximum number of staged header + bodies blocks records to be filled. If
    ## this size is reached, the process stops with staging with the exception
    ## of the lowest blockes (in case there is a gap.)
    ##
    ## This value might be adjusted with a larger value if
    ## `nFetchBodiesBatchDefault` is overridden with a smaller value.
    ##
    ## Some cursory measurements on `MainNet` suggest an average maximum block
    ## size ~25KiB (i.e. header + body) at block height ~4.5MiB. There will be
    ## as many as `nFetchBodiesBatch` blocks on a single staged blocks record.
    ## And there will be at most `blocksStagedQueueLengthMax+1` records on the
    ## staged blocks queue. (The `+1` is exceptional, appears when the least
    ## entry block number is too high and so leaves a gap to the ledger state
    ## block number.)

  finaliserChainLengthMax* = 32
    ## When importing with `importBlock()`, finalise after at most this many
    ## invocations of `importBlock()`.

  # ----------------------

static:
  doAssert 0 < runsThisManyPeersOnly

  doAssert 0 < nFetchHeadersRequest
  doAssert nFetchHeadersRequest <= nFetchHeadersBatch
  doAssert 0 < headersStagedQueueLengthLwm
  doAssert headersStagedQueueLengthLwm < headersStagedQueueLengthHwm

  doAssert 0 < nFetchBodiesRequest
  doAssert nFetchBodiesRequest <= nFetchBodiesBatchDefault
  doAssert 0 < blocksStagedQueueLenMaxDefault

# End
