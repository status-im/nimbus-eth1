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

import
  std/[sets, random],
  chronos,
  nimcrypto/keccak,
  stint,
  eth/[common/eth_types, p2p],
  ../../types,
  ../path_desc,
  ./fetch/[common, fetch_snap, fetch_trie],
  ./worker_desc

{.push raises: [Defect].}

logScope:
  topics = "snap fetch"

# Note: To test disabling snap (or trie), modify `fetchTrieOk` or
# `fetchSnapOk` where those are defined.

proc fetch*(sp: WorkerBuddy) {.async.} =
  var stateRoot = sp.ctrl.stateRoot.get
  trace "Syncing from stateRoot", peer=sp, stateRoot

  while true:
    if not sp.fetchTrieOk and not sp.fetchSnapOk:
      trace "No more sync available from this peer", peer=sp
      return

    if not sp.hasSlice():
      trace "Nothing more to sync from this peer", peer=sp
      while not sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.

    if sp.ctrl.stateRoot.isNone:
      trace "No current state root for this peer", peer=sp
      while sp.ctrl.stateRoot.isNone and
            (sp.fetchTrieOk or sp.fetchSnapOk) and
            sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if stateRoot != sp.ctrl.stateRoot.get:
      trace "Syncing from new stateRoot", peer=sp, stateRoot
      stateRoot = sp.ctrl.stateRoot.get
      sp.ctrl.setRunning

    if sp.ctrl.isStopRequest:
      trace "Pausing sync until we get a new state root", peer=sp
      while sp.ctrl.stateRoot.isSome and stateRoot == sp.ctrl.stateRoot.get and
            (sp.fetchTrieOk or sp.fetchSnapOk) and
            sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    var leafRange: LeafRange

    # Mix up different slice modes, because when connecting to static nodes one
    # mode or the other tends to dominate, which makes the mix harder to test.
    var allowSnap = true
    if sp.fetchSnapOk and sp.fetchTrieOk:
      if rand(99) < 50:
        allowSnap = false

    if sp.fetchSnapOk and allowSnap:
      discard sp.getSlice(leafRange)
      trace "GetAccountRange segment", peer=sp,
        leafRange=pathRange(leafRange.leafLow, leafRange.leafHigh), stateRoot
      await sp.fetchSnap(stateRoot, leafRange)

    elif sp.fetchTrieOk:
      discard sp.getSlice(leafRange)
      trace "GetNodeData segment", peer=sp,
        leafRange=pathRange(leafRange.leafLow, leafRange.leafHigh), stateRoot
      await sp.fetchTrie(stateRoot, leafRange)

proc fetchSetup*(sp: WorkerBuddy) =
  ## Initialise `WorkerBuddy` to support `ReplyData.new()` calls.
  sp.fetchTrieSetup
