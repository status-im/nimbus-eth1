# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [Defect].}

import
  std/[sets, random],
  chronos,
  nimcrypto/keccak,
  stint,
  eth/[common/eth_types, p2p],
  ".."/[path_desc, base_desc, types],
  "."/[common, fetch_trie, fetch_snap, peer_desc]

# Note: To test disabling snap (or trie), modify `peerSupportsGetNodeData` or
# `peerSupportsSnap` where those are defined.

proc stateFetch*(sp: SnapPeerEx) {.async.} =
  var stateRoot = sp.ctrl.stateRoot.get
  trace "Snap: Syncing from stateRoot", peer=sp, stateRoot

  while true:
    if not sp.peerSupportsGetNodeData() and not sp.peerSupportsSnap():
      trace "Snap: Cannot sync more from this peer", peer=sp
      return

    if not sp.hasSlice():
      trace "Snap: Nothing more to sync from this peer", peer=sp
      while not sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.

    if sp.ctrl.stateRoot.isNone:
      trace "Snap: No current state root for this peer", peer=sp
      while sp.ctrl.stateRoot.isNone and
            (sp.peerSupportsGetNodeData() or sp.peerSupportsSnap()) and
            sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if stateRoot != sp.ctrl.stateRoot.get:
      trace "Snap: Syncing from new stateRoot", peer=sp, stateRoot
      stateRoot = sp.ctrl.stateRoot.get
      sp.ctrl.runState = SyncRunningOK

    if sp.ctrl.runState == SyncStopRequest:
      trace "Snap: Pausing sync until we get a new state root", peer=sp
      while sp.ctrl.stateRoot.isSome and stateRoot == sp.ctrl.stateRoot.get and
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
      trace "Snap: snap.GetAccountRange segment", peer=sp,
        leafRange=pathRange(leafRange.leafLow, leafRange.leafHigh), stateRoot
      await sp.snapFetch(stateRoot, leafRange)

    elif sp.peerSupportsGetNodeData():
      discard sp.getSlice(leafRange)
      trace "Snap: eth.GetNodeData segment", peer=sp,
        leafRange=pathRange(leafRange.leafLow, leafRange.leafHigh), stateRoot
      await sp.trieFetch(stateRoot, leafRange)
