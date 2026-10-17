# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [], gcsafe.}

import
  unittest2,
  eth/rlp,
  eth/common/[hashes, headers, eth_types_rlp],
  ../engine/header_store

proc chainOf(count: int): seq[Header] =
  var
    headers: seq[Header]
    parentHash = default(Hash32)

  for i in 0 ..< count:
    let header = Header(number: BlockNumber(i), parentHash: parentHash)
    parentHash = header.computeBlockHash
    headers.add(header)

  headers

suite "test proxy header store":
  test "get from empty store":
    let store = HeaderStore.new(1)
    check store.get(default(Hash32), Optimistic).isNone()
    check store.get(default(BlockNumber), Optimistic).isNone()
    check store.getHash(Optimistic).isNone()
    check store.getHash(Safe).isNone()
    check store.getHash(Finalized).isNone()
    check store.len == 0
    check store.isEmpty()

  test "anchor hashes are kept per trust level":
    let
      store = HeaderStore.new(10)
      headers = chainOf(3)

    for h in headers:
      store.put(h, h.computeBlockHash, Optimistic)

    store.putHash(headers[2].computeBlockHash, Optimistic)
    store.putHash(headers[1].computeBlockHash, Safe)
    store.putHash(headers[0].computeBlockHash, Finalized)

    check store.getHash(Optimistic) == Opt.some(headers[2].computeBlockHash)
    check store.getHash(Safe) == Opt.some(headers[1].computeBlockHash)
    check store.getHash(Finalized) == Opt.some(headers[0].computeBlockHash)

  test "a get only hits at or above the requested trust":
    let
      store = HeaderStore.new(10)
      header = Header(number: BlockNumber(1))
      hash = header.computeBlockHash

    store.put(header, hash, Optimistic)

    check store.get(hash, Optimistic).isSome()
    check store.get(hash, Safe).isNone()
    check store.get(hash, Finalized).isNone()

    store.put(header, hash, Safe)

    check store.get(hash, Safe).isSome()
    check store.get(hash, Finalized).isNone()

  test "a put never lowers the trust of a cached header":
    let
      store = HeaderStore.new(10)
      header = Header(number: BlockNumber(1))
      hash = header.computeBlockHash

    store.put(header, hash, Finalized)
    store.put(header, hash, Optimistic)

    check store.get(hash, Finalized).isSome()

  test "the number index only serves finalized entries":
    let
      store = HeaderStore.new(10)
      header = Header(number: BlockNumber(7))
      hash = header.computeBlockHash

    store.put(header, hash, Safe)

    check store.get(BlockNumber(7), Optimistic).isNone()
    check store.getHash(BlockNumber(7), Optimistic).isNone()

    store.put(header, hash, Finalized)

    check store.get(BlockNumber(7), Finalized).isSome()
    check store.getHash(BlockNumber(7), Finalized) == Opt.some(hash)

  test "finalizing an anchor does not promote cached entries":
    let
      store = HeaderStore.new(10)
      headers = chainOf(5)

    for h in headers:
      store.put(h, h.computeBlockHash, Optimistic)

    store.putHash(headers[4].computeBlockHash, Finalized)

    check store.getHash(Finalized) == Opt.some(headers[4].computeBlockHash)

    for h in headers:
      check store.get(h.computeBlockHash, Optimistic).isSome()
      check store.get(h.computeBlockHash, Finalized).isNone()
      check store.getHash(h.number, Finalized).isNone()

  test "a header cached without trust is only served at None":
    let
      store = HeaderStore.new(10)
      header = Header(number: BlockNumber(3))
      hash = header.computeBlockHash

    store.put(header, hash, None)

    check store.get(hash, None).isSome()
    check store.get(hash, Optimistic).isNone()

  test "the number index is dropped when its header is evicted":
    let
      store = HeaderStore.new(2)
      headers = chainOf(3)

    for h in headers:
      store.put(h, h.computeBlockHash, Finalized)

    check store.len == 2
    check store.getHash(headers[0].number, Finalized).isNone()
    check store.getHash(headers[2].number, Finalized) ==
      Opt.some(headers[2].computeBlockHash)

  test "clear drops both the cache and the anchors":
    let
      store = HeaderStore.new(10)
      header = Header(number: BlockNumber(1))
      hash = header.computeBlockHash

    store.put(header, hash, Finalized)
    store.putHash(hash, Finalized)

    store.clear()

    check store.isEmpty()
    check store.getHash(Finalized).isNone()
    check store.get(hash, Optimistic).isNone()
    check store.get(BlockNumber(1), Finalized).isNone()
