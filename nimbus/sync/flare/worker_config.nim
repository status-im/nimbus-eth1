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
  enableTicker* = false or true
    ## Log regular status updates similar to metrics. Great for debugging.

  metricsUpdateInterval* = chronos.seconds(10)
    ## Wait at least this time before next update

  daemonWaitInterval* = chronos.seconds(30)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background.

  runMultiIdleWaitInterval* = chronos.seconds(30)
    ## Sllep some time in multi-mode if there is nothing to do

  nFetchHeadersRequest* = 1_024
    ## Number of headers that will be requested with a single `eth/xx` message.
    ## Generously calculating a header with size 1k, fetching 1_024 headers
    ## would amount to a megabyte. As suggested in
    ## github.com/ethereum/devp2p/blob/master/caps/eth.md#blockheaders-0x04,
    ## the size of a message should not exceed 2 MiB.
    ##
    ## On live tests, responses to larger requests where all truncted to 1024
    ## header entries. It makes sense to not ask for more. So reserving
    ## smaller unprocessed slots that mostly all will be served leads to less
    ## fragmentation on a multi-peer downloading approach.

  fetchHeaderReqZombieThreshold* = chronos.seconds(2)
    ## Response time allowance. If the response time for the set of headers
    ## exceeds this threshold, then this peer will be banned for a while.

  nFetchHeadersOpportunisticly* = 8 * nFetchHeadersRequest
    ## Length of the request/stage batch. Several headers are consecutively
    ## fetched and stashed together as a single record on the staged queue.
    ## This is the size of an opportunistic run where the record stashed on
    ## the queue might be later discarded.

  nFetchHeadersByTopHash* = 16 * nFetchHeadersRequest
    ## This entry is similar to `nFetchHeadersOpportunisticly` only that it
    ## will always be successfully merged into the database.

  stagedQueueLengthLwm* = 24
    ## Limit the number of records in the staged queue. They start accumulating
    ## if one peer stalls while fetching the top chain so leaving a gap. This
    ## gap must be filled first before inserting the queue into a contiguous
    ## chain of headers. So this is a low-water mark where the system will
    ## try some magic to mitigate this problem.

  stagedQueueLengthHwm* = 40
    ## If this size is exceeded, the staged queue is flushed and its contents
    ## is re-fetched from scratch.


static:
  doAssert 0 < nFetchHeadersRequest
  doAssert nFetchHeadersRequest <= nFetchHeadersOpportunisticly
  doAssert nFetchHeadersRequest <= nFetchHeadersByTopHash

# End
