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
  std/[math, paths, sets],
  pkg/[chronos, eth/common, minilru, results],
  ../../../core/chain,
  ../../sync_desc,
  ../../wire_protocol/types as wire_types,
  ./[extra_types, worker_const]

from ./cache_db/db_desc
  import CacheDbRef

# Running beacon syncer in tandem
from ../../beacon
  import BeaconPeerRef, BeaconSyncRef
from ../../beacon/worker/worker_const as beacon_const
  import BeaconState

export
  BeaconState,
  chain, common, results, extra_types, sync_desc, wire_types, worker_const

type
  SnapPeerRef* = SyncPeerRef[SnapCtxData,SnapPeerData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[SnapCtxData,SnapPeerData]
    ## Extended global descriptor

  EthBalHashSet* = LruCache[Hash,Hash32]
    ## Eth peer list of failed block access lists

  SnapCoreDb2Ref* = ref object
    ## Shared descriptor that contains some specs of the assembled database
    ## as the running/finished state of the snap sync process.
    waitSync*: bool                                 # Shutdown in progress
    snapSyncStop*: bool                             # Can be monitored

  # -------------------

  SnapError* = tuple
    ## Capture exception context for heders/bodies fetcher logging
    excp: ErrorType
    name: string
    msg: string
    elapsed: Duration

  SnapErrorEx* = tuple
    ## Extended `SnapError` for `eth` peer tracking with BALs
    excp: ErrorType
    name: string
    msg: string
    elapsed: Duration
    peerID: Hash

  FetchAccountsData* = tuple
    packet: AccountRangePacket
    elapsed: Duration

  FetchStorageData* = tuple
    packet: StorageRangesPacket
    elapsed: Duration

  FetchCodesData* = tuple
    packet: ByteCodesPacket
    elapsed: Duration

  FetchBalData* = tuple
    packet: BlockAccessListsPacket
    elapsed: Duration
    peerID: Hash                                    # remote peer (if any)

  StorageRangesData* = tuple
    ## Derived from `StorageRangesPacket`
    slots: seq[seq[StorageItem]]                    # Slots without proof
    partial: seq[StorageItem]                       # Incomplete slot with proof
    proof: seq[ProofNode]                           # Prof for `partial`

  # -------------------

  PeerErrors* = object
    ## Count fetching and processing errors
    fetch*: tuple[
      acc, sto, cde, bal: uint8]
    apply*: tuple[
      acc, sto, cde, bal: uint8]

  PeerFirstFetchReq* = object
    ## Register fetch request. This is intended to avoid sending the same (or
    ## similar) fetch request again from the same peer that sent it previously.
    stateRoot*: StateRoot            ## Accounts fetch (per state root)
    balHash*: Hash32                 ## Last failed BAL

  AccountBatch* = object
    ## Unresolved accounts register, download batch.
    accUnproc*: UnprocItemKeys       ## Account download sync
    accRefresh*: HashSet[Address]    ## Refresh addresses (after BAL forward)

  EtaSpline* = seq[(Moment,float)]                  # (x,y) pairs
    ## A set of at most three splines for interpolating a straight line
    ## supported by the first and the last spline. The first two splines
    ## must have minimum distance.

  SnapPeerData* = object
    ## Local descriptor data extension
    snapVersion*: int                ## For logging
    supportsBal*: bool               ## Peer supports BAL (snap2 and later)
    finRoot*: Opt[StateRoot]         ## Some finalised state root (if any)
    nErrors*: PeerErrors             ## Error register
    peerType*: string                ## Self declared peer type
    failedReq*: PeerFirstFetchReq    ## Don't send the same failed request twice
    lastMsgLog*: Moment              ## Helps reducing logging noise
    stateExhausted*: BlockNumber     ## Wait until pivot is forwarded
    notAvailBal*: BlockNumber        ## Similar to `stateExhausted`

  SnapCtxData* = object
    ## Globally shared data extension
    newCoreDb*: SnapCoreDb2Ref       ## Will become new database (or copy of)
    syncState*: SnapState            ## Last known layout state
    balSupported*: bool              ## Becomes `true` on `Amsterdam` or later
    contPrevSession*: bool           ## Request resuming previous session
    beaconSync*: BeaconSyncRef       ## Beacon syncer to resume after snap sync
    beaconTarget*: bool              ## Inital beacon target if `true`
    accBatch*: AccountBatch          ## Download & update processing data
    baseDir*: string                 ## Path for assembly database
    cacheDB*: CacheDbRef             ## Downloas and assembly cache database
    headersSynced*: bool             ## beacon sync headers
    pivotNum*: BlockNumber           ## Last applicable state block number
    forwardNum*: BlockNumber         ## Max possible BALs forward
    lastConsNum*: BlockNumber        ## Wait a bit until next header download
    balsLocked*: SnapPeerRef         ## Only one peer can download BALs
    nSnap2Peers*: int                ## # of Active snap/2 peers for proto use
    failedEthBalId*: EthBalHashSet   ## Ditto for eth peers
    resetReq*: bool                  ## Restart system (problem with cache data)
    etaSpline*: EtaSpline            ## Needed to calculate ETA

    # Info, debugging, and error handling stuff
    lastSlowPeer*: Opt[Hash]         ## Register slow peer when the last one
    lastPeerSeen*: chronos.Moment    ## Time when the last peer was abandoned
    lastNoPeersLog*: chronos.Moment  ## Control messages about missing peers
    lastNoHdrsLog*: chronos.Moment   ## Control update messages
    lastTrggHdrsLog*: chronos.Moment ## Control update messages
    lastMaxHdrsLog*: chronos.Moment  ## Control update messages
    lastBcSyncLog*: chronos.Moment   ## Control update messages
    lastNoBalSupport*: chronos.Moment ## Control update messages

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func chain*(ctx: SnapCtxRef): ForkedChainRef =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.chain

func hdrCache*(ctx: SnapCtxRef): HeaderChainRef =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.hdrCache

template accUnproc*(ctx: SnapCtxRef): untyped =
  ## Getter
  ctx.pool.accBatch.accUnproc

template accRefresh*(ctx: SnapCtxRef): untyped =
  ## Getter
  ctx.pool.accBatch.accRefresh

func beaconInitTarget*(ctx: SnapCtxRef): bool =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.initTarget.isSome()

func beaconState*(ctx: SnapCtxRef): BeaconState =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.syncState

func nErrors*(buddy: SnapPeerRef): var PeerErrors =
  ## Shortcut
  buddy.only.nErrors

func syncState*(ctx: SnapCtxRef): (SnapState, bool) =
  (ctx.pool.syncState, ctx.poolMode)

func syncState*(
    buddy: SnapPeerRef;
      ): (string, SyncPeerRunState, SnapState, bool) =
  (buddy.only.peerType,
   buddy.ctrl.state,
   buddy.ctx.pool.syncState,
   buddy.ctx.poolMode)


proc getSnapPeer*(buddy: SnapPeerRef; peerID: Hash): SnapPeerRef =
  ## Getter, retrieve syncer peer (aka buddy) by `peerID` argument.
  if buddy.peerID == peerID: buddy else: buddy.ctx.getSyncPeer peerID

proc getSnapPeers*(buddy: SnapPeerRef): seq[SnapPeerRef] =
  ## Getter, retrieve all currently active syncer peers (aka buddy)
  buddy.ctx.getSyncPeers()

proc nSnapPeers*(buddy: SnapPeerRef): int =
  ## Shortcut for `ctx.getSyncPeers().len`
  buddy.ctx.nSyncPeers()

proc getEthPeer*(buddy: SnapPeerRef): Opt[BeaconPeerRef] =
  ## Get the `eth` peer context for the current peer. This context is needed
  ## for running `eth` protocol requests.
  let ethPeer = buddy.ctx.pool.beaconSync.ctx.getSyncPeer buddy.peerID
  if ethPeer.isNil:
    return err()
  ok(ethPeer)

proc getEthPeers*(ctx: SnapCtxRef): seq[BeaconPeerRef] =
  ##  Get all `eth` peer contexts available at the current time
  ctx.pool.beaconSync.ctx.getSyncPeers()

proc nEthPeers*(ctx: SnapCtxRef): int =
  ## Shortcut for `beaconSync.ctx.getSyncPeers().len`
  ctx.pool.beaconSync.ctx.nSyncPeers()

# ---------

template logCtrl*(lastLog: var Moment, logWait: Duration, code: untyped) =
  block:
    let now = Moment.now()
    if lastLog + logWait < now:
      code
      lastLog = now

func fromBytes*(_: type Hash32, path: openArray[byte]): Hash32 =
  doAssert path.len == 32
  let path = @path
  (addr distinctBase(result)[0]).copyMem(unsafeAddr path[0], path.len)

func toStr*(error: SnapError): string =
  result = $error.excp
  if 0 < error.name.len:
    result &= "(" & error.name & ")"
  if 0 < error.msg.len:
    result &= "[" & error.msg & "]"

# ---------

proc clear*(spline: var EtaSpline) =
  spline.setLen(0)

proc apply*(spline: var EtaSpline, y: float) =
  let x = Moment.now()
  case spline.len:
  of 0, 2:
    spline.add (x,y)
  of 1:
     if etaSplineDistMin1 < x - spline[0][0]:
       # (x,y) has minimum distance from the first spline. so add it
       spline.add (x,y)
  of 3:
    if etaSplineDistMin2 < x - spline[1][0]:
      # (x,y) has minimum distance from the second spline. so replace the
      # three spline set by a spline tuple.
      spline = @[spline[1], (x,y)]
    else:
      # Replace last spline
      spline[2] = (x,y)
  else:
    raiseAssert "No more than 3 splines"

proc eta*(spline: EtaSpline): Opt[Duration] =
  if spline.len < 2:
    return err()

  template toNs(w: Moment): int64 =
    (w - Moment.low).nanoseconds

  let
    x0 = spline[0][0].toNs                          # unit: ns
    x1 = spline[^1][0].toNs                         # unit: ns
    y0 = spline[0][1]
    y1 = spline[^1][1]

  # This must have been made certain by the `apply()` function
  doAssert x0 + etaSplineDistMin1.nanoseconds <= x1

  if y0.almostEqual(y1) or y1 < y0:                 # infinite horizon
    return err()

  let
    # Straight line: `y = m x + c` with `m = (y1-y0)/(x1-x0)`, `c = y1 - m x1`
    m = (y1 - y0) / (x1 - x0).float                 # unit: 1/ns

    # Value 1 is reached at x9: `1 = m x9 + c` => `1 = m (x9 - x1) + y1`
    # At time x1, ETA is `x9 - x1 = (1 - y1) / m`
    H = (1.0 - y1) / m                              # unit: ns

  # Convert to nanoseconde from float
  ok(nanoseconds H.int64)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
