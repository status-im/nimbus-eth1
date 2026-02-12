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
  std/sets,
  pkg/[chronos, eth/common, minilru, results],
  ../../../core/chain,
  ../../sync_desc,
  ../../wire_protocol/types as wire_types,
  ./[state_db, worker_const]

from ./mpt/mpt_assembly
  import MptAsmRef
from ../../beacon
  import BeaconPeerRef, BeaconSyncRef

export
  chain, common, results, state_db, sync_desc, wire_types, worker_const


type
  SnapPeerRef* = SyncPeerRef[SnapCtxData,SnapPeerData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[SnapCtxData,SnapPeerData]
    ## Extended global descriptor

  StateRootSet* = LruCache[StateRoot,uint8]
    ## Used for avoiding sending the same failed request twice. This data
    ## structure is used as a self-cleaning hash set. The data argument is
    ## unused.

  # -------------------

  SnapError* = tuple
    ## Capture exception context for heders/bodies fetcher logging
    excp: ErrorType
    name: string
    msg: string
    elapsed: Duration

  FetchHeadersData* = tuple
    packet: BlockHeadersPacket
    elapsed: Duration

  FetchAccountsData* = tuple
    packet: AccountRangePacket
    elapsed: Duration

  FetchStorageData* = tuple
    packet: StorageRangesPacket
    elapsed: Duration

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
      acc, sto, cde, tri: uint8]     ## Accounts, storage, code, trie nodes
    apply*: tuple[
      acc, sto, cde, tri: uint8]

  PeerFirstFetchReq* = object
    ## Register fetch request. This is intended to avoid sending the same (or
    ## similar) fetch request again from the same peer that sent it previously.
    stateRoot*: StateRootSet         ## Account fetch (per state root)

  SnapPeerData* = object
    ## Local descriptor data extension
    pivotRoot*: Opt[StateRoot]       ## Derived from peer best/latest hash
    nErrors*: PeerErrors             ## Error register
    peerType*: string                ## Self declared peer type
    failedReq*: PeerFirstFetchReq    ## Don't send the same failed request twice

  SnapTarget* = tuple
    ## Bundled target settings
    blockHash: BlockHash
    updateFile: string

  SnapCtxData* = object
    ## Globally shared data extension
    syncState*: SyncState            ## Last known layout state
    beaconSync*: BeaconSyncRef       ## Beacon syncer to resume after snap sync
    stateDB*: StateDbRef             ## Incomplete states DB
    baseDir*: string                 ## Path for assembly database
    mptAsm*: MptAsmRef               ## Assembly database
    mptEla*: chronos.Duration        ## Accumulated MPT proof processing time

    # Preloading/manual state update
    target*: Opt[SnapTarget]         ## Optional for setting up a sync target
    stateUpdateChecked*: string      ## Last update value (avoids log spamming)

    # Info, debugging, and error handling stuff
    lastSlowPeer*: Opt[Hash]         ## Register slow peer when the last one
    failedPeers*: HashSet[Hash]      ## Detect dead end sync by collecting peers
    seenData*: bool                  ## Set `true` if data were fetched, already
    lastPeerSeen*: chronos.Moment    ## Time when the last peer was abandoned
    lastNoPeersLog*: chronos.Moment  ## Control messages about missing peers
    lastSyncUpdLog*: chronos.Moment  ## Control update messages
    ticker*: Ticker                  ## Ticker function to run in background

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func chain*(ctx: SnapCtxRef): ForkedChainRef =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.chain

func nErrors*(buddy: SnapPeerRef): var PeerErrors =
  ## Shortcut
  buddy.only.nErrors


func syncState*(ctx: SnapCtxRef): (SyncState, bool) =
  (ctx.pool.syncState, ctx.poolMode)

func syncState*(
    buddy: SnapPeerRef;
      ): (string, SyncPeerRunState, SyncState, bool) =
  (buddy.only.peerType,
   buddy.ctrl.state,
   buddy.ctx.pool.syncState,
   buddy.ctx.poolMode)


proc getSnapPeer*(buddy: SnapPeerRef; peerID: Hash): SnapPeerRef =
  ## Getter, retrieve syncer peer (aka buddy) by `peerID` argument.
  if buddy.peerID == peerID: buddy else: buddy.ctx.getSyncPeer peerID

proc getEthPeer*(buddy: SnapPeerRef): BeaconPeerRef =
  ## Get the `eth` peer context for the current peer. This context is needed
  ## for running `eth` protocol requests.
  buddy.ctx.pool.beaconSync.ctx.getSyncPeer buddy.peerID

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
