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
  # std/[sets, random],
  chronos,
  nimcrypto/keccak,
  stint,
  eth/[common/eth_types, p2p],
  ../../types,
  ./fetch/[common, fetch_snap], # fetch_trie],
  ./worker_desc

{.push raises: [Defect].}

logScope:
  topics = "snap fetch"

# Note: To test disabling snap (or trie), modify `fetchTrieOk` or
# `fetchSnapOk` where those are defined.

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc fetchSetup*(ns: Worker) =
  ## Global set up
  ns.commonSetup()

proc fetchRelease*(ns: Worker) =
  ## Global clean up
  ns.commonRelease()

proc fetchStart*(sp: WorkerBuddy) =
  ## Initialise `WorkerBuddy` to support `ReplyData.new()` calls.
  trace "Supported fetch modes", peer=sp,
    ctrlState=sp.ctrl.state, snapMode=sp.fetchSnapOk

proc fetchStop*(sp: WorkerBuddy) =
  ## Clean up for this peer
  discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetch*(sp: WorkerBuddy) {.async.} =

  var stateRoot = sp.ctrl.stateRoot.get
  trace "Syncing from stateRoot", peer=sp, stateRoot

  while sp.fetchSnapOk: # sp.fetchTrieOk or sp.fetchSnapOk:

    if not sp.hasSlice():
      trace "Nothing more to sync from this peer", peer=sp
      while not sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.

    if sp.ctrl.stateRoot.isNone:
      trace "No current state root for this peer", peer=sp
      while sp.ctrl.stateRoot.isNone and
            sp.fetchSnapOk and # (sp.fetchTrieOk or sp.fetchSnapOk) and
            sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if stateRoot != sp.ctrl.stateRoot.get:
      trace "Syncing from new stateRoot", peer=sp, stateRoot
      stateRoot = sp.ctrl.stateRoot.get
      sp.ctrl.stopped = false

    if sp.ctrl.stopRequest:
      trace "Pausing sync until we get a new state root", peer=sp
      while sp.ctrl.stateRoot.isSome and
            stateRoot == sp.ctrl.stateRoot.get and
            sp.fetchSnapOk and # (sp.fetchTrieOk or sp.fetchSnapOk) and
            sp.hasSlice():
        await sleepAsync(5.seconds) # TODO: Use an event trigger instead.
      continue

    if sp.fetchSnapOk: # and allowSnap:
      let leafRange = sp.getSlice.value
      trace "GetAccountRange segment", peer=sp, leafRange, stateRoot
      await sp.fetchSnap(stateRoot, leafRange)

  # while end

  trace "No more sync available from this peer", peer=sp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
