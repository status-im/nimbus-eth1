# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  #std/[dirs, paths, typetraits],
  std/[paths],
  #pkg/[chronicles, chronos, eth/common, results, rocksdb],
  pkg/[chronos, eth/common, rocksdb],
  pkg/stew/interval_set,
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db, #worker_const],
  ../mpt_desc

type
  BoolResult* = Result[bool,string]
    ## Shortcut

  BlobResult* = Result[seq[byte],string]
    ## Shortcut

  AccountDataResult* = Result[CacheAccountData,string]
    ## Shortcut

  OptHeaderResult* = Result[Opt[Header],string]
    ## Shortcut

  OptBalResult* = Result[Opt[BlockAccessListRef],string]
    ## Shortcut

  OptHashResult* = Result[Opt[Hash32],string]
    ## Shortcut

  OptAccMissingIntvResult* = Result[Opt[CacheAccMissingIntvData],string]
    ## Shortcut

  OptStoMissingIntvResult* = Result[Opt[CacheStoMissingIntvData],string]
    ## Shortcut

  OptFlatAccResult* = Result[Opt[Account],string]
    ## Shortcut

  OptFlatSlotResult* = Result[Opt[UInt256],string]
    ## Shortcut

  PutResult* = Result[void,string]
    ## Shortcut

  DelResult* = Result[void,string]
    ## Shortcut

  MptAsmRef* = ref object
    adb*: RocksDbReadWriteRef
    dir*: Path
    dnglLock*: int                                  # advisory lock
    cntrLock*: int                                  # advisory lock

  StateDataTag* = enum
    Untagged = 0                                    # well, still a tag :)
    OnTrie                                          # assembled and merged
    PivotOnTrie                                     # ditto, state root here
    PivotMptAnalysed

  CacheStateData* = tuple
    hash: BlockHash
    number: BlockNumber
    touch: Moment                                   # last data change
    tag: StateDataTag                               # how this record is used
    coverage: UInt256                               # account range coverage

  CacheAccountData* = tuple
    limit: ItemKey
    accounts: seq[SnapAccount]
    proof: seq[ProofNode]
    peerID: Hash

  DecodedStoSlot* = tuple
    limit: ItemKey
    slot: seq[StorageItem]
    proof: seq[ProofNode]
    peerID: Hash

  DecodedByteCode* = tuple
    limit: ItemKey
    codes: seq[(CodeHash,CodeItem)]
    peerID: Hash

  CacheAccMissingIntvData* = tuple
    root: StateRoot
    ranges: ItemKeyRangeSet

  CacheStoMissingIntvData* = tuple
    ranges: ItemKeyRangeSet

  WalkStateData* = tuple
    root: StateRoot
    data: CacheStateData
    error: string

  WalkAccountData* = tuple
    root: StateRoot
    start: ItemKey
    data: CacheAccountData
    error: string

  WalkStoSlot* = tuple
    root: StateRoot
    account: ItemKey
    start: ItemKey                                  # `0` unless incomplete
    limit: ItemKey                                  # `high()` unless incomplete
    slot: seq[StorageItem]
    proof: seq[ProofNode]                           # Prof for `slot` (if any)
    peerID: Hash
    error: string

  WalkByteCode* = tuple
    root: StateRoot
    start: ItemKey                                  # account coverage
    limit: ItemKey                                  # account coverage
    codes: seq[(CodeHash,CodeItem)]
    peerID: Hash
    error: string

  WalkHeader* = tuple
    header: Header
    error: string

  WalkBal* = tuple
    bal: BlockAccessListRef
    error: string

  WalkStoMissingIntvData* = tuple
    accPath: Hash32
    data: CacheStoMissingIntvData
    error: string

  WalkFlatAccData* = tuple
    accPath: Hash32
    data: Account
    error: string

  WalkFlatSlotData* = tuple
    accPath: Hash32
    slotKey: Hash32
    data: UInt256
    error: string

  KvPair* = tuple
    key: seq[byte]
    value: seq[byte]

# End
