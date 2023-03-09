# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  eth/p2p,
  chronos,
  ../sync_desc,
  ../misc/[best_pivot, block_queue],
  ./ticker

type
  PivotState* = enum
    PivotStateInitial,              ## Initial state
    FirstPivotSeen,                 ## Starting, first pivot seen
    FirstPivotAccepted,             ## Accepted, waiting for second
    FirstPivotUseRegardless         ## Force pivot if available
    PivotRunMode                    ## SNAFU after some magic

  FullBuddyData* = object
    ## Local descriptor data extension
    pivot*: BestPivotWorkerRef      ## Local pivot worker descriptor
    bQueue*: BlockQueueWorkerRef    ## Block queue worker

  FullCtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext       ## Random generator, pre-initialised
    pivot*: BestPivotCtxRef         ## Global pivot descriptor
    pivotState*: PivotState         ## For initial pivot control
    pivotStamp*: Moment             ## `PivotState` driven timing control
    bCtx*: BlockQueueCtxRef         ## Global block queue descriptor
    suspendAt*: BlockNumber         ## Suspend if persistent head is larger
    ticker*: TickerRef              ## Logger ticker

  FullBuddyRef* = BuddyRef[FullCtxData,FullBuddyData]
    ## Extended worker peer descriptor

  FullCtxRef* = CtxRef[FullCtxData]
    ## Extended global descriptor

# End
