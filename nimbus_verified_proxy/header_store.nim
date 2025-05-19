# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

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

type HeaderStore* = ref object
  headers: LruCache[Hash32, Header]
  hashes: LruCache[base.BlockNumber, Hash32]
  capacity: int

func convLCHeader*(lcHeader: ForkedLightClientHeader): Result[Header, string] =
  withForkyHeader(lcHeader):
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

    when lcDataFork > LightClientDataFork.Altair:
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
    capacity: max,
  )

func len*(self: HeaderStore): int =
  len(self.headers)

func isEmpty*(self: HeaderStore): bool =
  len(self.headers) == 0

proc add*(self: HeaderStore, header: ForkedLightClientHeader): Result[bool, string] =
  # Only add if it didn't exist before - the implementation of `latest` relies
  # on this..
  let execHeader = convLCHeader(header).valueOr:
    return err(error)
  withForkyHeader(header):
    when lcDataFork > LightClientDataFork.Altair:
      let execHash = forkyHeader.execution.block_hash.asBlockHash

      if execHash notin self.headers:
        self.headers.put(execHash, execHeader)
        self.hashes.put(execHeader.number, execHash)
  ok(true)

func latest*(self: HeaderStore): Opt[Header] =
  for h in self.headers.values:
    return Opt.some(h)

  Opt.none(Header)

func latestHash*(self: HeaderStore): Opt[Hash32] =
  for hash in self.headers.keys:
    return Opt.some(hash)

  Opt.none(Hash32)

func earliest*(self: HeaderStore): Opt[Header] =
  if self.headers.len() == 0:
    return Opt.none(Header)

  var hash: Hash32
  for h in self.headers.keys:
    hash = h

  self.headers.peek(hash)

func earliestHash*(self: HeaderStore): Opt[Hash32] =
  if self.headers.len() == 0:
    return Opt.none(Hash32)

  var hash: Hash32
  for h in self.headers.keys:
    hash = h

  Opt.some(hash)

func get*(self: HeaderStore, number: base.BlockNumber): Opt[Header] =
  let hash = self.hashes.peek(number).valueOr:
    return Opt.none(Header)

  return self.headers.peek(hash)

func get*(self: HeaderStore, hash: Hash32): Opt[Header] =
  self.headers.peek(hash)
