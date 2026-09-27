# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  unittest2,
  ../../execution_chain/db/aristo/[aristo_blobify, aristo_constants, aristo_desc],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/rdb_desc

suite "Aristo rdb cache key":
  test "Keys are distinct across roots and positions":
    let
      staticVid = VertexID(2)
      root1 = VertexID(FIRST_DYNAMIC_VID + 1)
      root2 = VertexID(FIRST_DYNAMIC_VID + 2)
      dyn = VertexID(FIRST_DYNAMIC_VID + 3)

    check:
      (root1, staticVid).toCacheKey() != (root2, staticVid).toCacheKey()
      (STATE_ROOT_VID, staticVid).toCacheKey() != (root1, staticVid).toCacheKey()
      (STATE_ROOT_VID, dyn).toCacheKey() != (dyn, dyn).toCacheKey()
      (root1, dyn).toCacheKey() != (dyn, root1).toCacheKey()
      (root1, dyn).toCacheKey() == (root1, dyn).toCacheKey()
      hash((root1, dyn).toCacheKey()) == hash((root1, dyn).toCacheKey())

  test "Upper bits of root and vid are kept":
    let
      lo = VertexID(0x0000_0001_0000_0002'u64)
      hi = VertexID(0x0001_0001_0000_0002'u64)

    check:
      (lo, lo).toCacheKey() != (hi, lo).toCacheKey()
      (lo, lo).toCacheKey() != (lo, hi).toCacheKey()
      (hi, lo).toCacheKey() != (lo, hi).toCacheKey()

  test "Branch value round trip":
    for (vid, used) in [
      (VertexID(0), 0'u16),
      (VertexID(0), 0xFFFF'u16),
      (VertexID(FIRST_DYNAMIC_VID), 0x8001'u16),
      (VertexID(0x0000_FFFF_FFFF_FFFF'u64), 0'u16),
      (VertexID(0x0000_FFFF_FFFF_FFFF'u64), 0xFFFF'u16),
    ]:
      let v = RdbBranchVal.init(vid, used)
      check:
        v.startVid == vid
        v.used == used

  test "Branch value rejects startVid beyond 48 bits":
    expect AssertionDefect:
      discard RdbBranchVal.init(VertexID(1'u64 shl 48), 0)

  test "Cache entry sizes":
    check:
      ConcurrentLruCache[RdbCacheKey, HashKey].entrySize == 60 + 12
      ConcurrentLruCache[RdbCacheKey, VertexBuf].entrySize == 144 + 12
      ConcurrentLruCache[RdbCacheKey, RdbBranchVal].entrySize == 32 + 12

  test "Cache keeps static vids under different roots apart":
    var lru: ConcurrentLruCache[RdbCacheKey, int]
    lru.init(16, shardBits = 0)
    defer:
      lru.dispose()

    let
      a = (STATE_ROOT_VID, VertexID(2))
      b = (VertexID(FIRST_DYNAMIC_VID + 1), VertexID(2))

    lru.put(a.toCacheKey(), 1)
    lru.put(b.toCacheKey(), 2)

    check:
      lru.peek(a.toCacheKey()) == Opt.some(1)
      lru.peek(b.toCacheKey()) == Opt.some(2)
