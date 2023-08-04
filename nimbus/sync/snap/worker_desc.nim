# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/[common, p2p],
  ../../db/select_backend,
  ../misc/ticker,
  ../sync_desc,
  ./worker/get/get_error,
  ./worker/db/[snapdb_desc]

export
  sync_desc # worker desc prototype

type
  SnapBuddyData* = object
    ## Peer-worker local descriptor data extension
    errors*: GetErrorStatsRef          ## For error handling
    full*: RootRef                     ## Peer local full sync descriptor
    # snap*: RootRef                   ## Peer local snap sync descriptor

  SnapSyncPassType* = enum
    ## Current sync mode, after a snapshot has been downloaded, the system
    ## proceeds with full sync.
    SnapSyncMode = 0                   ## Start mode
    FullSyncMode

  SnapSyncPass* = object
    ## Full specs for all sync modes. This table must be held in the main
    ## descriptor and initialised at run time. The table values are opaque
    ## and will be specified in the worker module(s).
    active*: SnapSyncPassType
    tab*: array[SnapSyncPassType,RootRef]

  SnapCtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext          ## Random generator
    snapDb*: SnapDbRef                 ## Accounts snapshot DB

    # Info
    beaconHeader*: BlockHeader         ## Running on beacon chain
    enableTicker*: bool                ## Advisary, extra level of gossip
    ticker*: TickerRef                 ## Ticker, logger descriptor

    # Snap/full mode muliplexing
    syncMode*: SnapSyncPass            ## Sync mode methods & data

    # Snap sync parameters, pivot table
    snap*: RootRef                     ## Global snap sync descriptor

    # Full sync continuation parameters
    fullHeader*: Option[BlockHeader]   ## Start full sync from here
    full*: RootRef                     ## Global full sync descriptor

  SnapBuddyRef* = BuddyRef[SnapCtxData,SnapBuddyData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[SnapCtxData]
    ## Extended global descriptor

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
