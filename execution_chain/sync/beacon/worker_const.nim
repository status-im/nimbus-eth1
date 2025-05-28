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

type SyncState* = enum
  idle = 0                         ## see clause *(8)*, *(12)* of `README.md`
  headers                          ## see clauses *(5)*, *(9)* of `README.md`
  headersCancel                    ## stop this scrum
  headersFinish                    ## see clause *(10)* of `README.md`
  blocks                           ## see clause *(11)* of `README.md`
  blocksCancel                     ## stop this syncer scrum
  blocksFinish                     ## get ready for `idle`

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

  workerIdleWaitInterval* = chronos.seconds(1)
    ## Sleep some time in multi-mode if there is nothing to do

  asyncThreadSwitchTimeSlot* = chronos.nanoseconds(1)
    ## Nano-sleep to allows pseudo/async thread switch

  asyncThreadSwitchGap* = chronos.milliseconds(300)
    ## Controls nano-sleep tart switch density when using this in a loop (e.g.
    ## for processing lists.) The constant requires a minimum time gap when
    ## invoking a nano-sleep utility.

  # ----------------------

  nFetchHeadersFailedInitialPeersThreshold* = 30
    ## If there are more failing peers than this threshold right at the
    ## begining of a header chain download scrum (before any data received),
    ## then this session (scrum or sprint) is discarded and the suncer is
    ## reset and suspened (waiting for the next activation to restart a new
    ## session.)

  nFetchHeadersRequest* = 1_024
    ## Number of headers that will be requested with a single `eth/xx` message.
    ##
    ## On `Geth`, responses to larger requests are all truncted to 1024 header
    ## entries (see `Geth` constant `maxHeadersServe`.)

  fetchHeadersErrTimeout* = chronos.seconds(2)
  nFetchHeadersErrThreshold* = 2
    ## Response time allowance. If the response time for the set of headers
    ## exceeds this threshold for more than `nFetchHeadersErrThreshold`
    ## times in a row, then this peer will be banned for a while.

  nProcHeadersErrThreshold* = 2
    ## Similar to `nFetchHeadersErrThreshold` but for the later part
    ## when errors occur while block headers are queued and further processed.

  fetchHeadersMinResponsePC* = 10
    ## Some peers only returned one header at a time. If these peers sit on a
    ## farm, they might collectively slow down the download process. So this
    ## constant sets a percentage of minimum headers needed to response with
    ## so that the peers is not treated as a slow responder (see also above
    ## for slow responder timeout.)

  nFetchHeadersBatchListLen* = 8 * nFetchHeadersRequest
    ## Length of a request/stage batch list. Several headers are consecutively
    ## fetched and stashed together as a single record on the staged queue.

  headersStagedQueueLengthMax* = 8
    ## If the staged header queue reaches this many queue objects for
    ## serialising and caching on disk, no further objects are added.

  # ----------------------

  nFetchBodiesFailedInitialPeersThreshold* = 50
    ## Similar to `nFetchHeadersFailedInitialPeersThreshold`.

  nFetchBodiesRequest* = 64
    ## Similar to `nFetchHeadersRequest`.

  fetchBodiesErrTimeout* = chronos.seconds(4)
  nFetchBodiesErrThreshold* = 2
    ## Similar to `nFetchHeadersErrThreshold`.

  fetchBodiesMinResponsePC* = 10
    ## Similar to ``fetchHeadersMinResponsePC`.

  nProcBlocksErrThreshold* = 2
    ## Similar to `nProcHeadersErrThreshold`.

  nImportBlocksErrThreshold* = 2
    ## Abort block import and the whole sync session with it if too many
    ## failed imports occur into `FC` module.

  blocksStagedQueueLengthMax* = 2
    ## Similar to `headersStagedQueueLengthMax`.

  # ----------------------

static:
  doAssert 0 < runsThisManyPeersOnly

  doAssert 0 < nFetchHeadersRequest
  doAssert nFetchHeadersRequest <= nFetchHeadersBatchListLen
  doAssert 0 < headersStagedQueueLengthMax

  doAssert 0 < nFetchBodiesRequest
  doAssert 0 < blocksStagedQueueLengthMax

# End
