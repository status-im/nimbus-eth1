# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  eth/common/[hashes, headers],
  web3/eth_api_types,
  std/tables,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common],
  beacon_chain/el/engine_api_conversions,
  minilru,
  results

from eth/common/blocks import EMPTY_UNCLE_HASH

type HeaderStore* = ref object
  headers: LruCache[Hash32, Header]
  hashes: LruCache[base.BlockNumber, Hash32]
  finalized: Opt[Header]
  finalizedHash: Opt[Hash32]
  earliest: Opt[Header]
  earliestHash: Opt[Hash32]

func convLCHeader(lcHeader: ForkedLightClientHeader): Result[Header, string] =
  withForkyHeader(lcHeader):
    when lcDataFork > LightClientDataFork.Altair:
      template p(): auto =
        forkyHeader.execution

      when lcDataFork >= LightClientDataFork.Capella:
        let withdrawalsRoot = Opt.some(p.withdrawals_root.asBlockHash)
      else:
        const withdrawalsRoot = Opt.none(Hash32)

      when lcDataFork >= LightClientDataFork.Deneb:
        let
          blobGasUsed = Opt.some(p.blob_gas_used)
          excessBlobGas = Opt.some(p.excess_blob_gas)
          parentBeaconBlockRoot = Opt.some(forkyHeader.beacon.parent_root.asBlockHash)
      else:
        const
          blobGasUsed = Opt.none(uint64)
          excessBlobGas = Opt.none(uint64)
          parentBeaconBlockRoot = Opt.none(Hash32)

      when lcDataFork >= LightClientDataFork.Electra:
        # INFO: there is no visibility of the execution requests hash in light client header
        let requestsHash = Opt.none(Hash32)
      else:
        const requestsHash = Opt.none(Hash32)

      let h = Header(
        parentHash: p.parent_hash.asBlockHash,
        ommersHash: EMPTY_UNCLE_HASH,
        coinbase: addresses.Address(p.fee_recipient.data),
        stateRoot: p.state_root.asBlockHash,
        transactionsRoot: p.transactions_root.asBlockHash,
        receiptsRoot: p.receipts_root.asBlockHash,
        logsBloom: FixedBytes[BYTES_PER_LOGS_BLOOM](p.logs_bloom.data),
        difficulty: DifficultyInt(0.u256),
        number: base.BlockNumber(p.block_number),
        gasLimit: GasInt(p.gas_limit),
        gasUsed: GasInt(p.gas_used),
        timestamp: EthTime(p.timestamp),
        extraData: seq[byte](p.extra_data),
        mixHash: p.prev_randao.data.to(Bytes32),
        nonce: default(Bytes8),
        baseFeePerGas: Opt.some(p.base_fee_per_gas),
        withdrawalsRoot: withdrawalsRoot,
        blobGasUsed: blobGasUsed,
        excessBlobGas: excessBlobGas,
        parentBeaconBlockRoot: parentBeaconBlockRoot,
        requestsHash: requestsHash,
      )

      return ok(h)
    else:
      # running verified  proxy for altair doesn't make sense
      return err("pre-bellatrix light client headers do not have execution header")

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
  # Only add if it didn't exist before - the implementation of `latest` relies
  # on this..
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

func updateFinalized*(
    self: HeaderStore, header: ForkedLightClientHeader
): Result[void, string] =
  let execHeader = convLCHeader(header).valueOr:
    return err(error)

  withForkyHeader(header):
    when lcDataFork > LightClientDataFork.Altair:
      ?self.updateFinalized(execHeader, forkyHeader.execution.block_hash.asBlockHash)

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

func add*(self: HeaderStore, header: ForkedLightClientHeader): Result[void, string] =
  let execHeader = convLCHeader(header).valueOr:
    return err(error)

  withForkyHeader(header):
    when lcDataFork > LightClientDataFork.Altair:
      ?self.add(execHeader, forkyHeader.execution.block_hash.asBlockHash)

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
