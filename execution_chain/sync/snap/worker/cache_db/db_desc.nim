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
  std/paths,
  pkg/[chronos, eth/common, rocksdb],
  pkg/stew/interval_set,
  ../mpt_build/build_desc

export
  build_desc

type
  CacheDbRef* = ref object
    adb*: RocksDbReadWriteRef
    dir*: Path

  BoolResult* = Result[bool,string]
    ## Shortcut

  BlobResult* = Result[seq[byte],string]
    ## Shortcut

  OptHeaderResult* = Result[Opt[Header],string]
    ## Shortcut

  OptNumberResult* = Result[Opt[BlockNumber],string]
    ## Shortcut

  OptBalResult* = Result[Opt[BlockAccessListRef],string]
    ## Shortcut

  OptHashResult* = Result[Opt[Hash32],string]
    ## Shortcut

  OptAccMissingIntvResult* = Result[Opt[CacheAccMissingIntvData],string]
    ## Shortcut

  OptStoMissingIntvResult* = Result[Opt[CacheStoMissingIntvData],string]
    ## Shortcut

  OptFlatAccResult* = Result[Opt[CacheFlatAccData],string]
    ## Shortcut

  OptFlatSlotResult* = Result[Opt[UInt256],string]
    ## Shortcut

  PutResult* = Result[void,string]
    ## Shortcut

  DelResult* = Result[void,string]
    ## Shortcut

  CacheAccMissingIntvData* = tuple
    number: BlockNumber
    ranges: ItemKeyRangeSet

  CacheStoMissingIntvData* = tuple
    ranges: ItemKeyRangeSet

  CacheFlatAccData* = tuple
    dirtyStorage: bool
    dirtyCode: bool
    account: Account

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
    data: CacheFlatAccData
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
