# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  chronicles,
  metrics,
  std/[os, strutils],
  stew/io2,
  ../config,
  ../common/common,
  beacon_chain/era_db,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/[forks, helpers],
  ../beacon/payload_conv

proc latestEraFile*(eraDir: string, cfg: RuntimeConfig): Result[(string, Era), string] =
  ## Find the latest era file in the era directory.
  var
    latestEra = 0
    latestEraFile = ""

  try:
    for kind, obj in walkDir eraDir:
      let (_, name, _) = splitFile(obj)
      let parts = name.split('-')
      if parts.len() == 3 and parts[0] == cfg.CONFIG_NAME:
        let era =
          try:
            parseBiggestInt(parts[1])
          except ValueError:
            return err("Invalid era number")
        if era > latestEra:
          latestEra = era
          latestEraFile = obj
  except OSError as e:
    return err(e.msg)

  if latestEraFile == "":
    err("No valid era files found")
  else:
    ok((latestEraFile, Era(latestEra)))

proc loadHistoricalRootsFromEra*(
    eraDir: string, cfg: RuntimeConfig
): Result[
    (
      HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT],
      HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT],
      Slot,
    ),
    string,
] =
  ## Load the historical_summaries from the latest era file.
  let
    (latestEraFile, latestEra) = ?latestEraFile(eraDir, cfg)
    f = ?EraFile.open(latestEraFile)
    slot = start_slot(latestEra)
  var bytes: seq[byte]

  ?f.getStateSSZ(slot, bytes)

  if bytes.len() == 0:
    return err("State not found")

  let state =
    try:
      newClone(readSszForkedHashedBeaconState(cfg, slot, bytes))
    except SerializationError as exc:
      return err("Unable to read state: " & exc.msg)

  withState(state[]):
    when consensusFork >= ConsensusFork.Capella:
      return ok(
        (
          forkyState.data.historical_roots,
          forkyState.data.historical_summaries,
          slot + 8192,
        )
      )
    else:
      return ok(
        (
          forkyState.data.historical_roots,
          HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT](),
          slot + 8192,
        )
      )

proc getTxs*(txs: seq[bellatrix.Transaction]): seq[common.Transaction] =
  var transactions = newSeqOfCap[common.Transaction](txs.len)
  for tx in txs:
    try:
      transactions.add(rlp.decode(tx.asSeq(), common.Transaction))
    except RlpError:
      return @[]
  return transactions

proc getWithdrawals*(x: seq[capella.Withdrawal]): seq[common.Withdrawal] =
  var withdrawals = newSeqOfCap[common.Withdrawal](x.len)
  for w in x:
    withdrawals.add(
      common.Withdrawal(
        index: w.index,
        validatorIndex: w.validator_index,
        address: EthAddress(w.address.data),
        amount: uint64(w.amount),
      )
    )
  return withdrawals

proc getEthBlock*(blck: ForkyTrustedBeaconBlock): Opt[EthBlock] =
  ## Convert a beacon block to an eth1 block.
  const consensusFork = typeof(blck).kind
  when consensusFork >= ConsensusFork.Bellatrix:
    let
      payload = blck.body.execution_payload
      txs = getTxs(payload.transactions.asSeq())
      ethWithdrawals =
        when consensusFork >= ConsensusFork.Capella:
          Opt.some(getWithdrawals(payload.withdrawals.asSeq()))
        else:
          Opt.none(seq[common.Withdrawal])
      withdrawalRoot =
        when consensusFork >= ConsensusFork.Capella:
          Opt.some(calcWithdrawalsRoot(ethWithdrawals.get()))
        else:
          Opt.none(common.Hash256)
      blobGasUsed =
        when consensusFork >= ConsensusFork.Deneb:
          Opt.some(payload.blob_gas_used)
        else:
          Opt.none(uint64)
      excessBlobGas =
        when consensusFork >= ConsensusFork.Deneb:
          Opt.some(payload.excess_blob_gas)
        else:
          Opt.none(uint64)
      parentBeaconBlockRoot =
        when consensusFork >= ConsensusFork.Deneb:
          Opt.some(common.Hash32(blck.parent_root.data))
        else:
          Opt.none(common.Hash32)

      header = BlockHeader(
        parentHash: Hash32(payload.parent_hash.data),
        ommersHash: EMPTY_UNCLE_HASH,
        coinbase: EthAddress(payload.fee_recipient.data),
        stateRoot: Root(payload.state_root.data),
        transactionsRoot: calcTxRoot(txs),
        receiptsRoot: Root(payload.receipts_root.data),
        logsBloom: BloomFilter(payload.logs_bloom.data),
        difficulty: 0.u256,
        number: payload.block_number,
        gasLimit: GasInt(payload.gas_limit),
        gasUsed: GasInt(payload.gas_used),
        timestamp: EthTime(payload.timestamp),
        extraData: payload.extra_data.asSeq(),
        mixHash: Bytes32 payload.prev_randao.data,
        nonce: default(BlockNonce),
        baseFeePerGas: Opt.some(payload.base_fee_per_gas),
        withdrawalsRoot: withdrawalRoot,
        blobGasUsed: blobGasUsed,
        excessBlobGas: excessBlobGas,
        parentBeaconBlockRoot: parentBeaconBlockRoot,
      )
    Opt.some EthBlock(
      header: header, transactions: txs, uncles: @[], withdrawals: ethWithdrawals
    )
  else:
    Opt.none(EthBlock)

proc getEthBlockFromEra*(
    db: EraDB,
    historical_roots: openArray[Eth2Digest],
    historical_summaries: openArray[HistoricalSummary],
    slot: Slot,
    cfg: RuntimeConfig,
): Opt[EthBlock] =
  let fork = cfg.consensusForkAtEpoch(slot.epoch)
  fork.withConsensusFork:
    type T = consensusFork.TrustedSignedBeaconBlock
    var tmp = new T
    # Pass in default Eth2Digest to avoid block root computation (it is not
    # needed in this case)
    tmp[] = db.getBlock(
      historical_roots, historical_summaries, slot, Opt.some(default(Eth2Digest)), T
    ).valueOr:
      return Opt.none(EthBlock)
    getEthBlock(tmp[].message)
