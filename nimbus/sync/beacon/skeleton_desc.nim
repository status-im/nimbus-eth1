# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/times,
  chronicles,
  results,
  eth/common/eth_types,
  ../../utils/utils,
  ../../db/core_db,
  ../../core/chain

export eth_types, core_db, chain, chronicles, results, times

{.push gcsafe, raises: [].}

logScope:
  topics = "skeleton"

type
  # Contiguous header chain segment that is backed by the database,
  # but may not be linked to the live chain. The skeleton downloader may produce
  # a new one of these every time it is restarted until the subchain grows large
  # enough to connect with a previous subchain.
  Segment* = ref object
    head*: uint64 # Block number of the newest header in the subchain
    tail*: uint64 # Block number of the oldest header in the subchain
    next*: Hash256 # Block hash of the next oldest header in the subchain

  # Database entry to allow suspending and resuming a chain sync.
  # As the skeleton header chain is downloaded backwards, restarts can and
  # will produce temporarily disjoint subchains. There is no way to restart a
  # suspended skeleton sync without prior knowledge of all prior suspension points.
  Progress* = ref object
    segments*: seq[Segment]
    linked*: bool
    canonicalHeadReset*: bool

  SkeletonConfig* = ref object
    fillCanonicalBackStep*: uint64
    subchainMergeMinimum*: uint64

  # The Skeleton chain class helps support beacon sync by accepting head blocks
  # while backfill syncing the rest of the chain.
  SkeletonRef* = ref object
    progress*: Progress
    pulled*: uint64 # Number of headers downloaded in this run
    filling*: bool # Whether we are actively filling the canonical chain
    started*: Time # Timestamp when the skeleton syncer was created
    logged*: Time # Timestamp when progress was last logged to user
    db*: CoreDbRef
    chain*: ChainRef
    conf*: SkeletonConfig
    fillLogIndex*: uint64

  SkeletonStatus* = enum
    SkeletonOk

    # SyncReorged is a signal that the head chain of
    # the current sync cycle was (partially) reorged, thus the skeleton syncer
    # should abort and restart with the new state.
    SyncReorged

    # ReorgDenied is returned if an attempt is made to extend the beacon chain
    # with a new header, but it does not link up to the existing sync.
    ReorgDenied

    # SyncMerged is a signal that the current sync cycle merged with
    # a previously aborted subchain, thus the skeleton syncer
    # should abort and restart with the new state.
    SyncMerged

    # Request to do fillCanonicalChain
    FillCanonical

  StatusAndNumber* = object
    status*: set[SkeletonStatus]
    number*: uint64

  StatusAndReorg* = object
    status*: set[SkeletonStatus]
    reorg*: bool

  BodyRange* = object
    min*: uint64
    max*: uint64
