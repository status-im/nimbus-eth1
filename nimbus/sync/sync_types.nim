# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Shared types, data structures and shared utilities used by the eth1
## network sync processes.

import
  std/options,
  stint, chronicles, chronos,
  eth/[common/eth_types, p2p],
  ./snap/[base_desc, path_desc, types]

type
  SnapSync* = ref object of RootObj
    ## Shared state among all peers of a syncing node.
    syncPeers*:             seq[SyncPeer]
    sharedFetch:            SharedFetchState        # Exported via templates.

  SyncPeer* = ref object
    ## Peer state tracking.
    ns*:                    SnapSync
    peer*:                  Peer                    # p2pProtocol(eth65).
    stopped*:               bool
    pendingGetBlockHeaders*:bool
    stats*:                 SnapPeerStats

    # Peer canonical chain head ("best block") search state.
    syncMode*:              SnapPeerMode
    bestBlockNumber*:       BlockNumber
    bestBlockHash*:         BlockHash
    huntLow*:               BlockNumber # Recent highest known present block.
    huntHigh*:              BlockNumber # Recent lowest known absent block.
    huntStep*:              typeof(BlocksRequest.skip)

    # State root to fetch state for.
    # This changes during sync and is slightly different for each peer.
    syncStateRoot*:         Option[TrieHash]

    nodeDataRequests:       NodeDataRequestQueue    # Exported via templates.
    fetch:                  FetchState              # Exported via templates.
    startedFetch*:          bool
    stopThisState*:         bool

  # Use `import snap/get_nodedata` to access the real type's methods.
  NodeDataRequestQueue {.inheritable, pure.} = ref object

  # Use `import snap/pie/trie_fetch` to access the real type's methods.
  SharedFetchState {.inheritable, pure.} = ref object

  # Use `import snap/pie/trie_fetch` to access the real type's methods.
  FetchState {.inheritable, pure.} = ref object

template nodeDataRequestsBase*(sp: SyncPeer): auto =
  sp.nodeDataRequests
template `nodeDataRequests=`*(sp: SyncPeer, value: auto) =
  sp.nodeDataRequests = value

template sharedFetchBase*(sp: SyncPeer): auto =
  sp.ns.sharedFetch
template `sharedFetch=`*(sp: SyncPeer, value: auto) =
  sp.ns.sharedFetch = value

template fetchBase*(sp: SyncPeer): auto =
  sp.fetch
template `fetch=`*(sp: SyncPeer, value: auto) =
  sp.fetch = value

## String output functions.

template `$`*(sp: SyncPeer): string = $sp.peer
