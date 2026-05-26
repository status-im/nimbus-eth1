# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import eth/common/[hashes, headers], std/tables, minilru, results

type HeaderStore* = ref object
  headers: LruCache[Hash32, Header]
  hashes: LruCache[base.BlockNumber, Hash32]
  finalized: Opt[Header]
  finalizedHash: Opt[Hash32]
  earliest: Opt[Header]
  earliestHash: Opt[Hash32]

func new*(T: type HeaderStore, max: int): T =
  HeaderStore(
    headers: LruCache[Hash32, Header].init(max),
    hashes: LruCache[base.BlockNumber, Hash32].init(max),
    finalized: Opt.none(Header),
    finalizedHash: Opt.none(Hash32),
    earliest: Opt.none(Header),
    earliestHash: Opt.none(Hash32),
  )

func clear*(self: HeaderStore) =
  self.headers = LruCache[Hash32, Header].init(self.headers.capacity)
  self.hashes = LruCache[base.BlockNumber, Hash32].init(self.headers.capacity)
  self.finalized = Opt.none(Header)
  self.finalizedHash = Opt.none(Hash32)
  self.earliest = Opt.none(Header)
  self.earliestHash = Opt.none(Hash32)

func len*(self: HeaderStore): int =
  len(self.headers)

func isEmpty*(self: HeaderStore): bool =
  len(self.headers) == 0

func latest*(self: HeaderStore): Opt[Header] =
  for h in self.headers.values:
    return Opt.some(h)

  Opt.none(Header)

func earliest*(self: HeaderStore): Opt[Header] =
  self.earliest

func earliestHash*(self: HeaderStore): Opt[Hash32] =
  self.earliestHash

func finalized*(self: HeaderStore): Opt[Header] =
  self.finalized

func finalizedHash*(self: HeaderStore): Opt[Hash32] =
  self.finalizedHash

func contains*(self: HeaderStore, hash: Hash32): bool =
  self.headers.contains(hash)

func contains*(self: HeaderStore, number: base.BlockNumber): bool =
  self.hashes.contains(number)

proc addHeader(self: HeaderStore, header: Header, hHash: Hash32) =
  # Only add if it didn't exist before
  if hHash notin self.headers:
    self.hashes.put(header.number, hHash)
    var flagEvicted = false
    for (evicted, key, value) in self.headers.putWithEvicted(hHash, header):
      if evicted:
        flagEvicted = true
        self.earliest = Opt.some(value)
        self.earliestHash = Opt.some(key)

    # because the iterator doesn't yield when only new items are being added
    # to the cache
    if self.earliest.isNone() and (not flagEvicted):
      self.earliest = Opt.some(header)
      self.earliestHash = Opt.some(hHash)

func updateFinalized*(
    self: HeaderStore, header: Header, hHash: Hash32
): Result[void, string] =
  # add header to the chain - if it already exists it won't be added
  self.addHeader(header, hHash)

  if self.finalized.isSome():
    if self.finalized.get().number < header.number:
      self.finalized = Opt.some(header)
      self.finalizedHash = Opt.some(hHash)
    else:
      return err("finalized update header is older")
  else:
    self.finalized = Opt.some(header)
    self.finalizedHash = Opt.some(hHash)

  return ok()

func add*(self: HeaderStore, header: Header, hHash: Hash32): Result[void, string] =
  let latestHeader = self.latest

  # check the ordering of headers. This allows for gaps but always maintains an incremental order
  if latestHeader.isSome():
    if header.number <= latestHeader.get().number:
      return err("block is older than the latest one")

  # add header to the store and update earliest
  self.addHeader(header, hHash)

  ok()

func latestHash*(self: HeaderStore): Opt[Hash32] =
  for hash in self.headers.keys:
    return Opt.some(hash)

  Opt.none(Hash32)

func getHash*(self: HeaderStore, number: base.BlockNumber): Opt[Hash32] =
  self.hashes.peek(number)

func get*(self: HeaderStore, number: base.BlockNumber): Opt[Header] =
  let hash = self.hashes.peek(number).valueOr:
    return Opt.none(Header)

  return self.headers.peek(hash)

func get*(self: HeaderStore, hash: Hash32): Opt[Header] =
  self.headers.peek(hash)
