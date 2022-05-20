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

import
  std/[sets, tables],
  chronos,
  stint,
  ../../types,
  ".."/[base_desc, path_desc]

type
  NodeDataRequestBase* = ref object of RootObj
    ## Stub object, to be inherited

  SingleNodeRequestBase* = ref object of RootObj
    ## Stub object, to be inherited

  NodeDataRequestQueue* = ref object
    liveRequests*:          HashSet[NodeDataRequestBase]
    empties*:               int
    # `OrderedSet` was considered instead of `seq` here, but it has a slow
    # implementation of `excl`, defeating the motivation for using it.
    waitingOnEmpties*:      seq[NodeDataRequestBase]
    beforeFirstHash*:       seq[NodeDataRequestBase]
    beforeFullHash*:        HashSet[NodeDataRequestBase]
    # We need to be able to lookup requests by the hash of reply data.
    # `ptr NodeHash` is used here so the table doesn't require an independent
    # copy of the hash.  The hash is part of the request object.
    itemHash*:              Table[ptr NodeHash, (NodeDataRequestBase, int)]

  FetchState* = ref object
    ## Account fetching state on a single peer.
    sp*:                    SnapPeerEx
    nodeGetQueue*:          seq[SingleNodeRequestBase]
    nodeGetsInFlight*:      int
    scheduledBatch*:        bool
    progressPrefix*:        string
    progressCount*:         int
    nodesInFlight*:         int
    getNodeDataErrors*:     int
    leafRange*:             LeafRange
    unwindAccounts*:        int64
    unwindAccountBytes*:    int64
    finish*:                Future[void]

  SnapPeerEx* = ref object of SnapPeerBase
    nodeDataRequests*:      NodeDataRequestQueue
    fetchState*:            FetchState

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*(sp: SnapPeerEx): string =
  $sp.SnapPeerBase

# ------------------------------------------------------------------------------
# Public getter
# ------------------------------------------------------------------------------

proc ex*(base: SnapPeerBase): SnapPeerEx =
  ## to extended object instance version
  base.SnapPeerEx

# ------------------------------------------------------------------------------
# Public setter
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
