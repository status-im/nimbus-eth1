# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[sets, tables, algorithm, random, sequtils],
  chronos, stint, nimcrypto/keccak,
  eth/[common/eth_types, rlp, p2p],
  "."/[sync_types, pie_common, pie_fetch_trie, pie_fetch_snap]

# Note: To test disabling snap (or trie), modify `peerSupportsGetNodeData` or
# `peerSupportsSnap` where those are defined.

proc stateFetch*(sp: SyncPeer) {.async.} =
  var stateRoot = sp.syncStateRoot.get
  trace "Sync: Syncing from stateRoot", stateRoot=($stateRoot), peer=sp

  while true:
    if not sp.peerSupportsGetNodeData() and not sp.peerSupportsSnap():
      trace "Sync: Cannot sync more from this peer", peer=sp
      return

    if not sp.hasSlice():
      trace "Sync: Nothing more to sync from this peer", peer=sp
      while not sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.

    if sp.syncStateRoot.isNone:
      trace "Sync: No current state root for this peer", peer=sp
      while sp.syncStateRoot.isNone and
            (sp.peerSupportsGetNodeData() or sp.peerSupportsSnap()) and
            sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if stateRoot != sp.syncStateRoot.get:
      trace "Sync: Syncing from new stateRoot", stateRoot=($stateRoot), peer=sp
      stateRoot = sp.syncStateRoot.get
      sp.stopThisState = false

    if sp.stopThisState:
      trace "Sync: Pausing sync until we get a new state root", peer=sp
      while sp.syncStateRoot.isSome and stateRoot == sp.syncStateRoot.get and
            (sp.peerSupportsGetNodeData() or sp.peerSupportsSnap()) and
            sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    var leafRange: LeafRange

    # Mix up different slice modes, because when connecting to static nodes one
    # mode or the other tends to dominate, which makes the mix harder to test.
    var allowSnap = true
    if sp.peerSupportsSnap() and sp.peerSupportsGetNodeData():
      if rand(99) < 50:
        allowSnap = false

    if sp.peerSupportsSnap() and allowSnap:
      discard sp.getSlice(leafRange)
      trace "Sync: snap.GetAccountRange segment",
        leafRange=pathRange(leafRange.leafLow, leafRange.leafHigh),
        stateRoot=($stateRoot), peer=sp
      await sp.snapFetch(stateRoot, leafRange)
    elif sp.peerSupportsGetNodeData():
      discard sp.getSlice(leafRange)
      trace "Sync: eth.GetNodeData segment",
        leafRange=pathRange(leafRange.leafLow, leafRange.leafHigh),
        stateRoot=($stateRoot), peer=sp
      await sp.trieFetch(stateRoot, leafRange)
