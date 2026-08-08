# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Single threaded comparison of minilru.LruCache against ConcurrentLruCache in
# its threadSafe = false mode, using the key and value types the aristo caches
# actually instantiate: Hash32 keys with storage slot and account payloads.
#
# This lives apart from bench_lru.nim because that file imports concurrency/lru
# with {.all.}, which brings the private `toSubhash` template into scope and
# makes minilru's own `toSubhash` ambiguous at instantiation.
#
# Pin to a single core when running this - on a hybrid CPU the scheduler will
# otherwise migrate the process between performance and efficiency cores and the
# result is dominated by which one it landed on:
#
#   taskset -c 2 build/bench_lru_minilru

{.used.}

import
  std/[strformat, strutils, times],
  unittest2,
  minilru,
  eth/trie/nibbles,
  ../../execution_chain/db/aristo/aristo_desc/[desc_identifiers, desc_structural],
  ../../execution_chain/concurrency/lru

const
  benchNameWidth = 30
  cacheCapacity = 1 shl 17 # 131072, a power of two so `and mask` covers it all
  benchOps = 2_000_000
  benchReps = 9

proc makeKeys(count: int): seq[Hash32] =
  # Keccak digests are uniformly distributed, so a cheap xorshift stands in
  var
    keys = newSeq[Hash32](count)
    s = 0x243F6A8885A308D3'u64
  for i in 0 ..< count:
    for limb in 0 ..< 4:
      s = s xor (s shl 13)
      s = s xor (s shr 7)
      s = s xor (s shl 17)
      copyMem(addr keys[i].data[limb * 8], addr s, 8)
  keys

proc slotValue(i: int): CachedStoLeaf =
  CachedStoLeaf(pfx: NibblesBuf.nibble(byte(i and 15)), stoData: u256(i + 1))

proc accountValue(i: int): CachedAccLeaf =
  CachedAccLeaf(
    empty: false,
    pfx: NibblesBuf.nibble(byte(i and 15)),
    account: AristoAccount(
      nonce: uint64(i + 1), balance: u256(i + 1), codeHash: default(Hash32)
    ),
    stoID: (isValid: true, vid: VertexID(uint64(i + 1))),
  )

template checksumOf(v: CachedStoLeaf): uint64 =
  v.stoData.truncate(uint64)

template checksumOf(v: CachedAccLeaf): uint64 =
  v.account.nonce

proc report(name: string, baseline, candidate: float): string =
  let
    baseNs = (baseline * 1_000_000_000.0) / benchOps.float
    candNs = (candidate * 1_000_000_000.0) / benchOps.float
  "  " & alignLeft(name, benchNameWidth) & align(fmt"{baseNs:.1f}", 9) &
    align(fmt"{candNs:.1f}", 9) & align(fmt"{baseline / candidate:.2f}x", 10)

template comparePair(name: string, minilruBody, concurrentBody: untyped): string =
  ## Time both implementations of an operation within the same repetition, so
  ## that clock drift moves the two measurements together rather than only the
  ## one that happened to run second.
  var
    bestBase = float.high
    bestCand = float.high
  for _ in 0 ..< benchReps:
    let t0 = epochTime()
    minilruBody
    let t1 = epochTime()
    concurrentBody
    let t2 = epochTime()
    bestBase = min(bestBase, t1 - t0)
    bestCand = min(bestCand, t2 - t1)
  report(name, bestBase, bestCand)

template runBench(name: string, valueType: typedesc, makeValue: untyped): untyped =
  block:
    let
      keys = makeKeys(cacheCapacity)
      mask = cacheCapacity - 1

    var mini = minilru.LruCache[Hash32, valueType].init(cacheCapacity)
    var conc: ConcurrentLruCache[Hash32, valueType]
    conc.init(cacheCapacity, shardBits = 0, threadSafe = false)
    defer:
      conc.dispose()

    for i in 0 ..< cacheCapacity:
      mini.put(keys[i], makeValue(i))
      conc.put(keys[i], makeValue(i))

    var checksum: uint64

    let
      putLine = comparePair("put"):
        for i in 0 ..< benchOps:
          mini.put(keys[i and mask], makeValue(i))
      do:
        for i in 0 ..< benchOps:
          conc.put(keys[i and mask], makeValue(i))

      getLine = comparePair("get"):
        for i in 0 ..< benchOps:
          let v = mini.get(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())
      do:
        for i in 0 ..< benchOps:
          let v = conc.get(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())

      peekLine = comparePair("peek"):
        for i in 0 ..< benchOps:
          let v = mini.peek(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())
      do:
        for i in 0 ..< benchOps:
          let v = conc.peek(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())

      containsLine = comparePair("contains"):
        for i in 0 ..< benchOps:
          if mini.contains(keys[i and mask]):
            checksum += 1
      do:
        for i in 0 ..< benchOps:
          if conc.contains(keys[i and mask]):
            checksum += 1

      updateLine = comparePair("update"):
        for i in 0 ..< benchOps:
          if mini.update(keys[i and mask], makeValue(i)):
            checksum += 1
      do:
        for i in 0 ..< benchOps:
          if conc.update(keys[i and mask], makeValue(i)):
            checksum += 1

      refreshLine = comparePair("refresh"):
        for i in 0 ..< benchOps:
          if mini.refresh(keys[i and mask], makeValue(i)):
            checksum += 1
      do:
        for i in 0 ..< benchOps:
          if conc.refresh(keys[i and mask], makeValue(i)):
            checksum += 1

      popLine = comparePair("pop then put"):
        for i in 0 ..< benchOps:
          let v = mini.pop(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())
          mini.put(keys[i and mask], makeValue(i))
      do:
        for i in 0 ..< benchOps:
          let v = conc.pop(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())
          conc.put(keys[i and mask], makeValue(i))

      putEvictedLine = comparePair("putWithEvicted"):
        for i in 0 ..< benchOps:
          for (_, _, evicted) in mini.putWithEvicted(keys[i and mask], makeValue(i)):
            checksum += checksumOf(evicted)
      do:
        for i in 0 ..< benchOps:
          let evicted = conc.putWithEvicted(keys[i and mask], makeValue(i))
          if evicted.isOk():
            checksum += checksumOf(evicted.unsafeGet())

      withGetLine = comparePair("withGet (vs minilru get)"):
        for i in 0 ..< benchOps:
          let v = mini.get(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())
      do:
        for i in 0 ..< benchOps:
          conc.withGet(keys[i and mask], v):
            checksum += checksumOf(v)

      withPeekLine = comparePair("withPeek (vs minilru peek)"):
        for i in 0 ..< benchOps:
          let v = mini.peek(keys[i and mask])
          if v.isOk():
            checksum += checksumOf(v.unsafeGet())
      do:
        for i in 0 ..< benchOps:
          conc.withPeek(keys[i and mask], v):
            checksum += checksumOf(v)

    debugEcho ""
    debugEcho "  ",
      name, ": key=Hash32(", sizeof(Hash32), "B) value=", astToStr(valueType), "(",
      sizeof(valueType), "B) entries=", cacheCapacity, " ops=", benchOps, " best of ",
      benchReps
    debugEcho "  ",
      alignLeft("operation", benchNameWidth), align("minilru", 9), align("conc", 9),
      align("speedup", 10)
    debugEcho putLine
    debugEcho getLine
    debugEcho peekLine
    debugEcho containsLine
    debugEcho updateLine
    debugEcho refreshLine
    debugEcho popLine
    debugEcho putEvictedLine
    debugEcho withGetLine
    debugEcho withPeekLine

    check:
      checksum != 0
      mini.len == cacheCapacity
      conc.len == cacheCapacity

suite "minilru vs ConcurrentLruCache (threadSafe = false), Hash32 keys":
  test "storage slot values":
    runBench("slots", CachedStoLeaf, slotValue)

  test "account values":
    runBench("accounts", CachedAccLeaf, accountValue)
