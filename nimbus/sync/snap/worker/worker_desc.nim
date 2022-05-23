# Nimbus - New sync approach - A fusion of snap, trie, beam and other methods
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
  eth/[common/eth_types, p2p],
  stew/[byteutils, keyed_queue, results],
  ../../types

{.push raises: [Defect].}

const
  seenBlocksMax = 500
    ## Internal size of LRU cache (for debugging)

type
  FetchTrieBase* = ref object of RootObj
    ## Stub object, to be inherited in file `fetch_trie.nim`

  ReplyDataBase* = ref object of RootObj
    ## Stub object, to be inherited in file `reply_data.nim`

  WorkerBase* = ref object of RootObj
    ## Stub object, to be inherited in file `worker.nim`

  BuddyStat* = distinct uint

  BuddyRunState* = enum
    BuddyRunningOk
    BuddyStopRequest
    BuddyStopped

  WorkerBuddyStats* = tuple
    ## Statistics counters for events associated with this peer.
    ## These may be used to recognise errors and select good peers.
    ok: tuple[
      reorgDetected:       BuddyStat,
      getBlockHeaders:     BuddyStat,
      getNodeData:         BuddyStat]
    minor: tuple[
      timeoutBlockHeaders: BuddyStat,
      unexpectedBlockHash: BuddyStat]
    major: tuple[
      networkErrors:       BuddyStat,
      excessBlockHeaders:  BuddyStat,
      wrongBlockHeader:    BuddyStat]

  WorkerBuddyCtrl* = tuple
    ## Control and state settings
    stateRoot:             Option[TrieHash]
      ## State root to fetch state for. This changes during sync and is
      ## slightly different for each peer.
    runState:              BuddyRunState

  # -------

  WorkerSeenBlocks = KeyedQueue[array[32,byte],BlockNumber]
    ## Temporary for pretty debugging, `BlockHash` keyed lru cache

  CommonBase* = ref object of RootObj
    ## Stub object, to be inherited in file `common.nim`

  # -------

  WorkerBuddy* = ref object
    ## Non-inheritable peer state tracking descriptor.
    ns*: Worker                      ## Worker descriptor object back reference
    peer*: Peer                      ## Reference to eth p2pProtocol entry
    stats*: WorkerBuddyStats         ## Statistics counters
    ctrl*: WorkerBuddyCtrl           ## Control and state settings

    workerBase*: WorkerBase          ## Opaque object reference
    replyDataBase*: ReplyDataBase    ## Opaque object reference
    fetchTrieBase*: FetchTrieBase    ## Opaque object reference

  Worker* = ref object of RootObj
    ## Shared state among all peers of a snap syncing node. Will be
    ## amended/inherited into `WorkerCtx` by the `snap` module.
    seenBlock: WorkerSeenBlocks      ## Temporary, debugging, pretty logs

    commonBase*: CommonBase          ## Opaque object reference

# ------------------------------------------------------------------------------
# Public Constructor
# ------------------------------------------------------------------------------

proc new*(
    T: type WorkerBuddy;
    ns: Worker;
    peer: Peer;
    runState: BuddyRunState
      ): T =
  ## Initial state, maximum uncertainty range.
  T(ns:           ns,
    peer:         peer,
    ctrl: (
      stateRoot:  none(TrieHash),
      runState:   runState))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*(sp: WorkerBuddy): string =
  $sp.peer

proc inc(stat: var BuddyStat) {.borrow.}

# ------------------------------------------------------------------------------
# Public functions, debugging helpers (will go away eventually)
# ------------------------------------------------------------------------------

proc pp*(sn: Worker; bh: BlockHash): string =
  ## Pretty printer for debugging
  let rc = sn.seenBlock.lruFetch(bh.untie.data)
  if rc.isOk:
    return "#" & $rc.value
  $bh.untie.data.toHex

proc pp*(sn: Worker; bh: BlockHash; bn: BlockNumber): string =
  ## Pretty printer for debugging
  let rc = sn.seenBlock.lruFetch(bh.untie.data)
  if rc.isOk:
    return "#" & $rc.value
  "#" & $sn.seenBlock.lruAppend(bh.untie.data, bn, seenBlocksMax)

proc pp*(sn: Worker; bhn: HashOrNum): string =
  if not bhn.isHash:
    return "num(#" & $bhn.number & ")"
  let rc = sn.seenBlock.lruFetch(bhn.hash.data)
  if rc.isOk:
    return "hash(#" & $rc.value & ")"
  return "hash(" & $bhn.hash.data.toHex & ")"

proc seen*(sn: Worker; bh: BlockHash; bn: BlockNumber) =
  ## Register for pretty printing
  if not sn.seenBlock.lruFetch(bh.untie.data).isOk:
    discard sn.seenBlock.lruAppend(bh.untie.data, bn, seenBlocksMax)

# -----------

import
  ../../../tests/replay/pp_light

proc pp*(bh: BlockHash): string =
  bh.Hash256.pp

proc pp*(bn: BlockNumber): string =
  if bn == high(BlockNumber): "#max"
  else: "#" & $bn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
