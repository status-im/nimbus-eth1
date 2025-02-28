# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import 
  eth/common/hashes,
  eth/common/headers,
  web3/eth_api_types,
  std/tables,
  beacon_chain/spec/beaconstate,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/[light_client, nimbus_binary_common, version],
  beacon_chain/el/engine_api_conversions,
  minilru, 
  results

type
  HeaderStore* = ref object
    headers: LruCache[Hash32, Header]
    hashes: Table[base.BlockNumber, Hash32]

func convHeader(lcHeader: ForkedLightClientHeader): Header = 
  withForkyHeader(lcHeader):
    template p(): auto = forkyHeader.execution

    when lcDataFork >= LightClientDataFork.Capella:
      let withdrawalsRoot = Opt.some(p.withdrawals_root.asBlockHash)
    else:
      let withdrawalsRoot = Opt.none(Hash32)

    when lcDataFork >= LightClientDataFork.Deneb:
      let 
        blobGasUsed = Opt.some(p.blob_gas_used)
        excessBlobGas = Opt.some(p.excess_blob_gas)
        parentBeaconBlockRoot = Opt.some(forkyHeader.beacon.parent_root.asBlockHash)
    else:
      let 
        blobGasUsed = Opt.none(uint64)
        excessBlobGas = Opt.none(uint64)
        parentBeaconBlockRoot = Opt.none(Hash32)

    when lcDataFork >= LightClientDataFork.Electra:
      # TODO: there is no visibility of the execution requests hash in light client header 
      let requestsHash = Opt.none(Hash32)
    else:
      let requestsHash = Opt.none(Hash32)

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
        requestsHash: requestsHash
      )
    else:
      # INFO: should never reach this point because running verified
      # proxy for altair doesn't make sense
      let h = Header()
    return h

proc new*(T: type HeaderStore, max: int): T =
  HeaderStore(headers: LruCache[Hash32, Header].init(max))

func len*(self: HeaderStore): int =
  len(self.headers)

func isEmpty*(self: HeaderStore): bool =
  len(self.headers) == 0

proc add*(self: HeaderStore, header: ForkedLightClientHeader) =
  # Only add if it didn't exist before - the implementation of `latest` relies
  # on this..
  let execHeader = convHeader(header)
  withForkyHeader(header):
    when lcDataFork > LightClientDataFork.Altair:
      let execHash = forkyHeader.execution.block_hash.asBlockHash

      if execHash notin self.headers:
        self.headers.put(execHash, execHeader)
        self.hashes[execHeader.number] = execHash

proc latest*(self: HeaderStore): Opt[Header] =
  for h in self.headers.values:
    return Opt.some(h)

  Opt.none(Header)

proc get*(self: HeaderStore, number: base.BlockNumber): Opt[Header] =
  let hash = 
    try:
      self.hashes[number]
    except:
      return Opt.none(Header)

  return self.headers.peek(hash)

proc get*(self: HeaderStore, hash: Hash32): Opt[Header] =
  self.headers.peek(hash)
