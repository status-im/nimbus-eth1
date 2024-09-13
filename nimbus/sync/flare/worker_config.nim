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
  enableTicker* = true
    ## Log regular status updates similar to metrics. Great for debugging.

  runOnSinglePeerOnly* = false
    ## Run on a single peer only at a time. Great for debugging.

  # ----------------------

  metricsUpdateInterval* = chronos.seconds(10)
    ## Wait at least this time before next update

  daemonWaitInterval* = chronos.seconds(30)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background.

  runNoHeadersIdleWaitInterval* = chronos.seconds(30)
    ## Sllep some time in multi-mode if there is nothing to do

  # ----------------------

  nFetchHeadersRequest* = 1_024
    ## Number of headers that will be requested with a single `eth/xx` message.
    ##
    ## On `Geth`, responses to larger requests are all truncted to 1024 header
    ## entries (see `Geth` constant `maxHeadersServe`.)

  fetchHeaderReqThresholdZombie* = chronos.seconds(2)
  fetchHeaderReqThresholdCount* = 3
    ## Response time allowance. If the response time for the set of headers
    ## exceeds this threshold for more than `fetchHeaderReqThresholdCount`
    ## times in a row, then this peer will be banned for a while.

  nFetchHeadersBatch* = 8 * nFetchHeadersRequest
    ## Length of the request/stage batch. Several headers are consecutively
    ## fetched and stashed together as a single record on the staged queue.

  headersStagedQueueLengthLwm* = 32
    ## Limit the number of records in the staged queue. They start accumulating
    ## if one peer stalls while fetching the top chain so leaving a gap. This
    ## gap must be filled first before inserting the queue into a contiguous
    ## chain of headers. So this is a low-water mark where the system will
    ## try some magic to mitigate this problem.

  headersStagedQueueLengthHwm* = 48
    ## If this size is exceeded, the staged queue is flushed and its contents
    ## is re-fetched from scratch.

  # ----------------------

static:
  doAssert 0 < nFetchHeadersRequest
  doAssert nFetchHeadersRequest <= nFetchHeadersBatch
  doAssert 0 < headersStagedQueueLengthLwm
  doAssert headersStagedQueueLengthLwm < headersStagedQueueLengthHwm

# End
