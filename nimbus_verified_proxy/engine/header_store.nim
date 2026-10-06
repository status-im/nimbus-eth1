# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import eth/common/[hashes, headers], std/tables, minilru, results

type
  HeaderTrust* = enum
    None
    Optimistic
    Safe
    Finalized

  CachedHeader = object
    header: Header
    trust: HeaderTrust

  HeaderStore* = ref object
    headers: LruCache[Hash32, CachedHeader]
    hashes: Table[base.BlockNumber, Hash32]
    latestHash: Opt[Hash32]
    safeHash: Opt[Hash32]
    finalizedHash: Opt[Hash32]
    earliestFinalizedHash: Opt[Hash32]

func new*(T: type HeaderStore, max: int): T =
  HeaderStore(
    headers: LruCache[Hash32, CachedHeader].init(max),
    hashes: initTable[base.BlockNumber, Hash32](),
    latestHash: Opt.none(Hash32),
    safeHash: Opt.none(Hash32),
    finalizedHash: Opt.none(Hash32),
    earliestFinalizedHash: Opt.none(Hash32),
  )

func clear*(self: HeaderStore) =
  self.headers = LruCache[Hash32, CachedHeader].init(self.headers.capacity)
  self.hashes.clear()
  self.latestHash = Opt.none(Hash32)
  self.safeHash = Opt.none(Hash32)
  self.finalizedHash = Opt.none(Hash32)
  self.earliestFinalizedHash = Opt.none(Hash32)

func len*(self: HeaderStore): int =
  len(self.headers)

func isEmpty*(self: HeaderStore): bool =
  len(self.headers) == 0

func getHash*(self: HeaderStore, trust: HeaderTrust): Opt[Hash32] =
  case trust
  of None: Opt.none(Hash32)
  of Optimistic: self.latestHash
  of Safe: self.safeHash
  of Finalized: self.finalizedHash

func getEarliestHash*(self: HeaderStore): Opt[Hash32] =
  self.earliestFinalizedHash

func getHash*(
    self: HeaderStore, number: base.BlockNumber, minTrust: HeaderTrust
): Opt[Hash32] =
  let hash = self.hashes.getOrDefault(number, default(Hash32))
  if hash == default(Hash32):
    return Opt.none(Hash32)

  let cached = self.headers.peek(hash).valueOr:
    return Opt.none(Hash32)

  if cached.trust < minTrust:
    return Opt.none(Hash32)

  Opt.some(hash)

func get*(self: HeaderStore, hash: Hash32, minTrust: HeaderTrust): Opt[Header] =
  let cached = self.headers.peek(hash).valueOr:
    return Opt.none(Header)

  if cached.trust < minTrust:
    return Opt.none(Header)

  Opt.some(cached.header)

func get*(
    self: HeaderStore, number: base.BlockNumber, minTrust: HeaderTrust
): Opt[Header] =
  let hash = self.getHash(number, minTrust).valueOr:
    return Opt.none(Header)

  self.get(hash, minTrust)

func putCache(self: HeaderStore, hash: Hash32, header: Header, trust: HeaderTrust) =
  for (evicted, key, value) in
      self.headers.putWithEvicted(hash, CachedHeader(header: header, trust: trust)):
    if evicted and
        self.hashes.getOrDefault(value.header.number, default(Hash32)) == key:
      self.hashes.del(value.header.number)

  if trust == Finalized:
    self.hashes[header.number] = hash

func put*(self: HeaderStore, header: Header, hash: Hash32, trust: HeaderTrust) =
  let
    existing = self.headers.peek(hash)
    newTrust =
      if existing.isSome() and existing.get().trust > trust:
        existing.get().trust
      else:
        trust

  self.putCache(hash, header, newTrust)

func putHash*(self: HeaderStore, hash: Hash32, trust: HeaderTrust) =
  case trust
  of None:
    discard
  of Optimistic:
    self.latestHash = Opt.some(hash)
  of Safe:
    self.safeHash = Opt.some(hash)
  of Finalized:
    self.finalizedHash = Opt.some(hash)
    if self.earliestFinalizedHash.isNone():
      self.earliestFinalizedHash = Opt.some(hash)
