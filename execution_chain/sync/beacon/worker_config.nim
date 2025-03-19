# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
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
    ## Note:
    ##   This setting has priority over the `maxPeers` setting of the
    ##   `BeaconSyncRef.init()` initaliser.

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

  asyncThreadSwitchGap* = chronos.milliseconds(300)
    ## Controls nano-sleep tart switch density when using this in a loop (e.g.
    ## for processing lists.) The constant requires a minimum time gap when
    ## invoking a nano-sleep utility.

  # ----------------------

  fetchHeadersFailedInitialFailPeersHwm* = 30
    ## If there are more failing peers than this `hwm` right at the begining
    ## of a header chain download scrum (before any data received), then this
    ## scrum is discarded and the suncer is reset and suspened (waiting for
    ## the next instruction to run a scrum.)

  nFetchHeadersRequest* = 1_024
    ## Number of headers that will be requested with a single `eth/xx` message.
    ##
    ## On `Geth`, responses to larger requests are all truncted to 1024 header
    ## entries (see `Geth` constant `maxHeadersServe`.)

  fetchHeadersReqErrThresholdZombie* = chronos.seconds(2)
  fetchHeadersReqErrThresholdCount* = 2
    ## Response time allowance. If the response time for the set of headers
    ## exceeds this threshold for more than `fetchHeadersReqThresholdCount`
    ## times in a row, then this peer will be banned for a while.

  fetchHeadersProcessErrThresholdCount* = 2
    ## Similar to `fetchHeadersReqErrThresholdCount` but for the later part
    ## when errors occur while block headers are queued and further processed.

  fetchHeadersReqMinResponsePC* = 10
    ## Some peers only returned one header at a time. If these peers sit on a
    ## farm, they might collectively slow down the download process. So this
    ## constant sets a percentage of minimum headers needed to return so that
    ## the peers is not treated as a slow responder (see above for slow
    ## responder count.)

  nFetchHeadersBatch* = 8 * nFetchHeadersRequest
    ## Length of the request/stage batch. Several headers are consecutively
    ## fetched and stashed together as a single record on the staged queue.

  headersStagedQueueLengthLwm* = 16
    ## Limit the number of records in the staged headers queue.
    ##
    ## Queue entries start accumulating if one peer stalls while fetching the
    ## top chain so leaving a gap. This gap must be filled first before
    ## inserting the queue into a contiguous chain of headers.
    ##
    ## This low-water mark tryggers the system to do some **magic** to mitigate
    ## the above problem. Currently the **magic** is to let (pseudo) threads
    ## terminate and then restart all over again.

  headersStagedQueueLengthHwm* = 24
    ## If this size is exceeded, the staged queue is flushed and resized to
    ## `headersStagedQueueLengthLwm-1` entries. Then contents is re-fetched
    ## from scratch.

  # ----------------------

  fetchBodiesFailedInitialFailPeersHwm* = 50
    ## Similar to `fetchHeadersFailedInitialFailPeersHwm`

  nFetchBodiesRequest* = 128
    ## Similar to `nFetchHeadersRequest`

  fetchBodiesReqErrThresholdZombie* = chronos.seconds(4)
  fetchBodiesReqErrThresholdCount* = 3
    ## Similar to `fetchHeadersReqThreshold*`

  fetchBodiesProcessErrThresholdCount* = 2
    ## Similar to `fetchHeadersProcessErrThresholdCount`.

  fetchBodiesReqMinResponsePC* = 10
    ## Similar to `fetchHeadersReqMinResponsePC`

  fetchBodiesReqMinAvgBodySize* = 90 * 1024
    ## Calculatory body size to figure out the minimum expected response size
    ## when applying `fetchBodiesReqMinResponsePC`. On `mainnet`, an average
    ## body size of 90KiB/block is typical at block height ~#22m.

  nFetchBodiesBatch* = 3 * nFetchBodiesRequest
    ## Similar to `nFetchHeadersBatch`, this limits the record size of the
    ## the blocks queue.
    ##
    ## Similar to the minimum expected response size, the block count argument
    ## is translated into the calculatory data size of a block (i.e.
    ## header+body), `nFetchBodiesBatch * (fetchBodiesReqMinAvgBodySize+1024)`.

  blocksStagedHwmDefault* = 8 * nFetchBodiesBatch
    ## This is an initialiser value for `blocksStagedHwm`.
    ##
    ## If the staged block queue exceeds this many number of block objects for
    ## import, no further block objets are added (but the current sub-list is
    ## completed.)

  blocksStagedLwm* = nFetchBodiesBatch
    ## Minimal accepted initialisation value for `blocksStagedHwm`. The latter
    ## will be initalised with `blocksStagedHwmDefault` if smaller than the LWM.

  finaliserChainLengthMax* = 32 # -- to be obsoleted soon
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
  doAssert nFetchBodiesRequest <= nFetchBodiesBatch
  doAssert 0 < blocksStagedLwm
  doAssert blocksStagedLwm <= blocksStagedHwmDefault

# End
