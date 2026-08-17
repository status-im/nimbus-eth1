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
  pkg/[chronos, eth/common, minilru, results],
  ../../../core/chain,
  ../../sync_desc,
  ../../wire_protocol/types as wire_types,
  ./[state_db, worker_const]

from ./mpt/mpt_cache/cache_desc
  import CacheDbRef

# Running beacon syncer in tandem
from ../../beacon
  import BeaconPeerRef, BeaconSyncRef
from ../../beacon/worker/worker_const as beacon_const
  import BeaconState

export
  BeaconState,
  chain, common, results, state_db, sync_desc, wire_types, worker_const


type
  SnapPeerRef* = SyncPeerRef[SnapCtxData,SnapPeerData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[SnapCtxData,SnapPeerData]
    ## Extended global descriptor

  EthBalHashSet* = LruCache[Hash,Hash32]
    ## Eth peer list of failed block access lists

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
    slot: seq[StorageItem]                          # Incomplete slot with proof
    proof: seq[ProofNode]                           # Prof for `slot`

  Ticker* =
    proc(ctx: SnapCtxRef) {.gcsafe, raises: [].}
      ## Some function that is invoked regularly

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
    ethBalHash*: EthBalHashSet       ## Ditto for eth peers

  SnapPeerData* = object
    ## Local descriptor data extension
    supportsBal*: bool               ## Peer supports BAL (snap2 and later)
    finRoot*: Opt[StateRoot]         ## Some finalised state root (if any)
    notAvailMax*: BlockNumber        ## Max block number of rejected states
    nErrors*: PeerErrors             ## Error register
    peerType*: string                ## Self declared peer type
    failedReq*: PeerFirstFetchReq    ## Don't send the same failed request twice
    lastMsgLog*: Moment              ## Helps reducing logging noise
    stateExhausted*: BlockNumber     ## Wait until state is forwarded

  SnapCtxData* = object
    ## Globally shared data extension
    syncState*: SnapState            ## Last known layout state
    contPrevSession*: bool           ## Request resuming previous session
    beaconSync*: BeaconSyncRef       ## Beacon syncer to resume after snap sync
    beaconTarget*: bool              ## inital beacon target if `true`
    accUnproc*: UnprocItemKeys       ## Account download sync
    baseDir*: string                 ## Path for assembly database
    cacheDB*: CacheDbRef             ## Downloas and assembly cache database
    headersSynced*: bool             ## beacon sync headers
    pivotNum*: BlockNumber           ## Current appl;icable state block number
    forwardNum*: BlockNumber         ## Max possible BALs forward
    balsLocked*: SnapPeerRef         ## Only one peer can download BALs

    # Info, debugging, and error handling stuff
    lastSlowPeer*: Opt[Hash]         ## Register slow peer when the last one
    lastPeerSeen*: chronos.Moment    ## Time when the last peer was abandoned
    lastNoPeersLog*: chronos.Moment  ## Control messages about missing peers
    lastNoHdrsLog*: chronos.Moment   ## Control update messages
    lastMaxHdrsLog*: chronos.Moment  ## Control update messages
    ticker*: Ticker                  ## Ticker function to run in background

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func chain*(ctx: SnapCtxRef): ForkedChainRef =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.chain

func hdrCache*(ctx: SnapCtxRef): HeaderChainRef =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.hdrCache

func accUnproc*(ctx: SnapCtxRef): var UnprocItemKeys =
  ## Getter
  ctx.pool.accUnproc

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

proc getEthPeer*(buddy: SnapPeerRef): Opt[BeaconPeerRef] =
  ## Get the `eth` peer context for the current peer. This context is needed
  ## for running `eth` protocol requests.
  let ethPeer = buddy.ctx.pool.beaconSync.ctx.getSyncPeer buddy.peerID
  if ethPeer.isNil:
    return err()
  ok(ethPeer)

proc getEthPeers*(buddy: SnapPeerRef): seq[BeaconPeerRef] =
  ##  Get all `eth` peer contexts available at the current time
  buddy.ctx.pool.beaconSync.ctx.getSyncPeers()

proc nEthPeers*(ctx: SnapCtxRef): int =
  ## Shortcut for `buddy.getSyncPeers().len`
  ctx.pool.beaconSync.ctx.nSyncPeers()

# ---------

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
