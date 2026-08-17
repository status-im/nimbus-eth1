# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[sequtils, typetraits],
  eth/common/eth_types_rlp,
  eth/trie/ordered_trie,
  beacon_chain/spec/forks,
  ./web3_eth_conv,
  ./payload_conv,
  ../core/pooled_txs

from beacon_chain/spec/engine_types as engine_ssz_types import
  BlobsBundleV1, BlobsBundleV2, ExecutionRequests, MAX_BYTES_PER_EXECUTION_REQUEST,
  ExecutionPayloadBodyParis, ExecutionPayloadBodyShanghai, ExecutionPayloadBodyAmsterdam,
  ExecutionPayloadParis, ExecutionPayloadShanghai, ExecutionPayloadCancun,
  ExecutionPayloadAmsterdam

func toHash32*(d: Eth2Digest): Hash32 =
  d.data.to(Hash32)

func toDigest*(h: Hash32): Eth2Digest =
  Eth2Digest(data: h.data)

func ethTx*(bytes: openArray[byte]): transactions.Transaction {.raises: [RlpError].} =
  rlp.decode(bytes, transactions.Transaction)

func ethTxs*[T](list: openArray[T]): seq[transactions.Transaction]
    {.raises: [RlpError].} =
  var txs = newSeqOfCap[transactions.Transaction](list.len)
  for x in list:
    txs.add ethTx(asSeq(x))
  txs

func sszTx*(tx: transactions.Transaction): bellatrix.Transaction =
  bellatrix.Transaction.init(rlp.encode(tx))

func sszTxs*(list: openArray[transactions.Transaction]): seq[bellatrix.Transaction] =
  var txs = newSeqOfCap[bellatrix.Transaction](list.len)
  for tx in list:
    txs.add sszTx(tx)
  txs

func sszTxsAmsterdam*(list: openArray[transactions.Transaction]): seq[gloas.Transaction] =
  var txs = newSeqOfCap[gloas.Transaction](list.len)
  for tx in list:
    txs.add gloas.Transaction.init(rlp.encode(tx))
  txs

func ethWithdrawal*(w: capella.Withdrawal): blocks.Withdrawal =
  blocks.Withdrawal(
    index: w.index,
    validatorIndex: w.validator_index,
    address: w.address,
    amount: uint64(w.amount))

func ethWithdrawals*(list: openArray[capella.Withdrawal]): seq[blocks.Withdrawal] =
  var withdrawals = newSeqOfCap[blocks.Withdrawal](list.len)
  for w in list:
    withdrawals.add ethWithdrawal(w)
  withdrawals

func sszWithdrawal*(w: blocks.Withdrawal): capella.Withdrawal =
  capella.Withdrawal(
    index: w.index,
    validator_index: w.validatorIndex,
    address: w.address,
    amount: Gwei(w.amount))

func sszWithdrawals*(list: openArray[blocks.Withdrawal]): seq[capella.Withdrawal] =
  var withdrawals = newSeqOfCap[capella.Withdrawal](list.len)
  for w in list:
    withdrawals.add sszWithdrawal(w)
  withdrawals

template append(w: var RlpWriter, txBytes: bellatrix.Transaction) =
  w.appendRawBytes(asSeq(txBytes))

template append(w: var RlpWriter, txBytes: gloas.Transaction) =
  w.appendRawBytes(asSeq(txBytes))

func txRoot(list: openArray[bellatrix.Transaction]): Hash32 =
  orderedTrieRoot(list)

func txRoot(list: openArray[gloas.Transaction]): Hash32 =
  orderedTrieRoot(list)

func wdRoot(list: openArray[capella.Withdrawal]): Hash32 =
  orderedTrieRoot(ethWithdrawals(list))

func ethBlock*(p: ForkyExecutionPayload,
                 parentBeaconBlockRoot: Opt[Hash32],
                 requestsHash: Opt[Hash32]): Block {.raises: [RlpError].} =
  let
    withdrawalsRoot =
      when p is ExecutionPayloadParis:
        Opt.none(Hash32)
      else:
        Opt.some(wdRoot(asSeq(p.withdrawals)))
    blobGasUsed =
      when p is ExecutionPayloadCancun or p is ExecutionPayloadAmsterdam:
        Opt.some(p.blob_gas_used)
      else:
        Opt.none(uint64)
    excessBlobGas =
      when p is ExecutionPayloadCancun or p is ExecutionPayloadAmsterdam:
        Opt.some(p.excess_blob_gas)
      else:
        Opt.none(uint64)
    blockAccessListHash =
      when p is ExecutionPayloadAmsterdam:
        balHash(Opt.some(asSeq(p.block_access_list)))
      else:
        Opt.none(Hash32)
    slotNumber =
      when p is ExecutionPayloadAmsterdam:
        Opt.some(uint64(p.slot_number))
      else:
        Opt.none(uint64)
    withdrawals =
      when p is ExecutionPayloadParis:
        Opt.none(seq[blocks.Withdrawal])
      else:
        Opt.some(ethWithdrawals(asSeq(p.withdrawals)))

  Block(
    header: Header(
      parentHash     : toHash32(p.parent_hash),
      ommersHash     : EMPTY_UNCLE_HASH,
      coinbase       : p.fee_recipient,
      stateRoot      : toHash32(p.state_root),
      transactionsRoot: txRoot(asSeq(p.transactions)),
      receiptsRoot   : toHash32(p.receipts_root),
      logsBloom      : Bytes256(p.logs_bloom.data),
      difficulty     : 0.u256,
      number         : p.block_number,
      gasLimit       : p.gas_limit,
      gasUsed        : p.gas_used,
      timestamp      : EthTime(p.timestamp),
      extraData      : asSeq(p.extra_data),
      mixHash        : Bytes32(toHash32(p.prev_randao)),
      nonce          : default(Bytes8),
      baseFeePerGas  : Opt.some(p.base_fee_per_gas),
      withdrawalsRoot: withdrawalsRoot,
      blobGasUsed    : blobGasUsed,
      excessBlobGas  : excessBlobGas,
      parentBeaconBlockRoot: parentBeaconBlockRoot,
      requestsHash   : requestsHash,
      blockAccessListHash: blockAccessListHash,
      slotNumber     : slotNumber,
    ),
    uncles: @[],
    transactions: ethTxs(asSeq(p.transactions)),
    withdrawals: withdrawals,
  )

func ethBlockAccessList*(p: ForkyExecutionPayload): Opt[BlockAccessListRef] {.raises: [RlpError].} =
  when p is ExecutionPayloadAmsterdam:
    Opt.some(ethBlockAccessList(asSeq(p.block_access_list)))
  else:
    Opt.none(BlockAccessListRef)

func sszPayload*[T: ForkyExecutionPayload](blk: Block,
    bal = Opt.none(BlockAccessListRef)): T =
  let header = blk.header
  var res = T(
    parent_hash: toDigest(header.parentHash),
    fee_recipient: header.coinbase,
    state_root: toDigest(header.stateRoot),
    receipts_root: toDigest(header.receiptsRoot),
    logs_bloom: BloomLogs(data: array[256, byte](header.logsBloom)),
    prev_randao: toDigest(Hash32(header.mixHash)),
    block_number: header.number,
    gas_limit: header.gasLimit,
    gas_used: header.gasUsed,
    timestamp: uint64(header.timestamp),
    extra_data: typeof(default(T).extra_data).init(header.extraData),
    base_fee_per_gas: header.baseFeePerGas.get(0.u256),
    block_hash: toDigest(header.computeRlpHash))

  when T is ExecutionPayloadAmsterdam:
    res.transactions = sszTxsAmsterdam(blk.transactions)
  else:
    res.transactions = typeof(default(T).transactions).init(sszTxs(blk.transactions))

  when T isnot ExecutionPayloadParis:
    let withdrawals = blk.withdrawals.get(newSeq[blocks.Withdrawal]())
    when T is ExecutionPayloadAmsterdam:
      res.withdrawals = sszWithdrawals(withdrawals)
    else:
      res.withdrawals = typeof(default(T).withdrawals).init(sszWithdrawals(withdrawals))

  # ExecutionPayloadPrague*/Osaka* are aliases of ExecutionPayloadCancun
  when T is ExecutionPayloadCancun or T is ExecutionPayloadAmsterdam:
    res.blob_gas_used = header.blobGasUsed.get(0'u64)
    res.excess_blob_gas = header.excessBlobGas.get(0'u64)

  when T is ExecutionPayloadAmsterdam:
    let balBytes = if bal.isSome(): bal.get()[].encode() else: newSeq[byte]()
    res.block_access_list = typeof(default(T).block_access_list).init(balBytes)
    res.slot_number = gloas.Slot(header.slotNumber.get(0'u64))

  res

func sszBody*[T: ExecutionPayloadBodyParis | ExecutionPayloadBodyShanghai | ExecutionPayloadBodyAmsterdam](
    blk: Block, bal = Opt.none(BlockAccessListRef)): T =
  var res = T(
    transactions: typeof(default(T).transactions).init(sszTxs(blk.transactions)))

  when T isnot ExecutionPayloadBodyParis:
    res.withdrawals = typeof(default(T).withdrawals).init(
      sszWithdrawals(blk.withdrawals.get(newSeq[blocks.Withdrawal]())))

  when T is ExecutionPayloadBodyAmsterdam:
    let balBytes = if bal.isSome(): bal.get()[].encode() else: newSeq[byte]()
    res.block_access_list = typeof(default(T).block_access_list).init(balBytes)

  res

func sszBlobsBundleV1*(b: pooled_txs.BlobsBundle): engine_ssz_types.BlobsBundleV1 =
  doAssert(b.wrapperVersion == WrapperVersionEIP4844)
  type T = engine_ssz_types.BlobsBundleV1
  T(
    commitments: typeof(default(T).commitments).init(
      b.commitments.mapIt(deneb.KzgCommitment(bytes: distinctBase(it)))),
    proofs: typeof(default(T).proofs).init(
      b.proofs.mapIt(deneb.KzgProof(bytes: distinctBase(it)))),
    blobs: typeof(default(T).blobs).init(
      b.blobs.mapIt(deneb.Blob(distinctBase(it)))))

func sszBlobsBundleV2*(b: pooled_txs.BlobsBundle): engine_ssz_types.BlobsBundleV2 =
  doAssert(b.wrapperVersion == WrapperVersionEIP7594)
  type T = engine_ssz_types.BlobsBundleV2
  T(
    commitments: typeof(default(T).commitments).init(
      b.commitments.mapIt(deneb.KzgCommitment(bytes: distinctBase(it)))),
    proofs: typeof(default(T).proofs).init(
      b.proofs.mapIt(deneb.KzgProof(bytes: distinctBase(it)))),
    blobs: typeof(default(T).blobs).init(
      b.blobs.mapIt(deneb.Blob(distinctBase(it)))))

func sszExecutionRequests*(reqs: seq[seq[byte]]): engine_ssz_types.ExecutionRequests =
  engine_ssz_types.ExecutionRequests.init(
    reqs.mapIt(ByteList[Limit MAX_BYTES_PER_EXECUTION_REQUEST].init(it)))

func ethExecutionRequests*(reqs: engine_ssz_types.ExecutionRequests): seq[seq[byte]] =
  asSeq(reqs).mapIt(asSeq(it))
