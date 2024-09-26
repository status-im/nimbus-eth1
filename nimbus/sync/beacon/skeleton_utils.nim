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
  ./skeleton_desc

{.push gcsafe, raises: [].}

logScope:
  topics = "skeleton"

const
  # How often to log sync status (in ms)
  STATUS_LOG_INTERVAL* = initDuration(microseconds = 8000)
  zeroBlockHash* = default(Hash256)

# ------------------------------------------------------------------------------
# Misc helpers
# ------------------------------------------------------------------------------

func u64*(h: BlockHeader): uint64 =
  h.number

func blockHash*(x: Opt[BlockHeader]): Hash256 =
  if x.isSome: x.get.blockHash
  else: zeroBlockHash

func numberStr*(x: Opt[BlockHeader]): string =
  if x.isSome: $(x.get.u64)
  else: "N/A"

func blockHashStr*(x: Opt[BlockHeader]): string =
  if x.isSome: x.get.blockHash.short
  else: "N/A"

func blockHashStr*(x: BlockHeader): string =
  x.blockHash.short

# ------------------------------------------------------------------------------
# Segment helpers
# ------------------------------------------------------------------------------

func segment*(head, tail: uint64, next: Hash256): Segment =
  Segment(head: head, tail: tail, next: next)

func short(s: Segment): string =
  s.next.short

func `$`*(s: Segment): string =
  result = "head: " & $s.head &
         ", tail: " & $s.tail &
         ", next: " & s.short

# ------------------------------------------------------------------------------
# Progress helpers
# ------------------------------------------------------------------------------

proc add*(ss: Progress, s: Segment) =
  ss.segments.add s

proc add*(ss: Progress, head, tail: uint64, next: Hash256) =
  ss.add Segment(head: head, tail: tail, next: next)

# ------------------------------------------------------------------------------
# SkeletonRef helpers
# ------------------------------------------------------------------------------

func isEmpty*(sk: SkeletonRef): bool =
  sk.progress.segments.len == 0

func notEmpty*(sk: SkeletonRef): bool =
  sk.progress.segments.len > 0

func blockHeight*(sk: SkeletonRef): uint64 =
  sk.chain.com.syncCurrent

func genesisHash*(sk: SkeletonRef): Hash256 =
  sk.chain.com.genesisHash

func com*(sk: SkeletonRef): CommonRef =
  sk.chain.com

func len*(sk: SkeletonRef): int =
  sk.progress.segments.len

func last*(sk: SkeletonRef): Segment =
  sk.progress.segments[^1]

func second*(sk: SkeletonRef): Segment =
  sk.progress.segments[^2]

iterator subchains*(sk: SkeletonRef): Segment =
  for sub in sk.progress.segments:
    yield sub

iterator pairs*(sk: SkeletonRef): (int, Segment) =
  for i, sub in sk.progress.segments:
    yield (i, sub)

proc push*(sk: SkeletonRef, s: Segment) =
  sk.progress.add s

proc push*(sk: SkeletonRef, head, tail: uint64, next: Hash256) =
  sk.progress.add(head, tail, next)

proc removeLast*(sk: SkeletonRef) =
  discard sk.progress.segments.pop

proc removeSecond*(sk: SkeletonRef) =
  sk.progress.segments.delete(sk.len-2)

proc removeAllButLast*(sk: SkeletonRef) =
  let last = sk.progress.segments.pop
  for sub in sk.subchains:
    debug "Canonical subchain linked with main, removing junked chains", sub
  sk.progress.segments = @[last]

proc clear*(sk: SkeletonRef) =
  sk.progress.segments.setLen(0)
