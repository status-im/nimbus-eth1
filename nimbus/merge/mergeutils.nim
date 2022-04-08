import
  std/[typetraits, times, strutils],
  nimcrypto/[hash, sha2],
  web3/engine_api_types,
  eth/[trie, rlp, common, trie/db],
  stew/[objects, results, byteutils],
  ../constants,
  ./mergetypes

import eth/common/eth_types except BlockHeader

proc computePayloadId*(headBlockHash: Hash256, params: PayloadAttributesV1): PayloadID =
  var dest: Hash256
  var ctx: sha256
  ctx.init()
  ctx.update(headBlockHash.data)
  ctx.update(toBytesBE distinctBase params.timestamp)
  ctx.update(distinctBase params.prevRandao)
  ctx.update(distinctBase params.suggestedFeeRecipient)
  ctx.finish dest.data
  ctx.clear()
  (distinctBase result)[0..7] = dest.data[0..7]

template unsafeQuantityToInt64(q: Quantity): int64 =
  int64 q

template asEthHash*(hash: engine_api_types.BlockHash): Hash256 =
  Hash256(data: distinctBase(hash))

proc calcRootHashRlp*(items: openArray[seq[byte]]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i), t)
  return tr.rootHash()

proc toBlockHeader*(payload: ExecutionPayloadV1): eth_types.BlockHeader =
  let transactions = seq[seq[byte]](payload.transactions)
  let txRoot = calcRootHashRlp(transactions)

  EthBlockHeader(
    parentHash    : payload.parentHash.asEthHash,
    ommersHash    : EMPTY_UNCLE_HASH,
    coinbase      : EthAddress payload.feeRecipient,
    stateRoot     : payload.stateRoot.asEthHash,
    txRoot        : txRoot,
    receiptRoot   : payload.receiptsRoot.asEthHash,
    bloom         : distinctBase(payload.logsBloom),
    difficulty    : default(DifficultyInt),
    blockNumber   : payload.blockNumber.distinctBase.u256,
    gasLimit      : payload.gasLimit.unsafeQuantityToInt64,
    gasUsed       : payload.gasUsed.unsafeQuantityToInt64,
    timestamp     : fromUnix payload.timestamp.unsafeQuantityToInt64,
    extraData     : bytes payload.extraData,
    mixDigest     : payload.prevRandao.asEthHash, # EIP-4399 redefine `mixDigest` -> `prevRandao`
    nonce         : default(BlockNonce),
    fee           : some payload.baseFeePerGas
  )

template toHex*(x: Hash256): string =
  toHex(x.data)

template validHash*(x: Hash256): Option[BlockHash] =
  some(BlockHash(x.data))

proc validate*(header: eth_types.BlockHeader, gotHash: Hash256): Result[void, string] =
  let wantHash = header.blockHash
  if wantHash != gotHash:
    return err("blockhash mismatch, want $1, got $2" % [wantHash.toHex, gotHash.toHex])

  return ok()

proc simpleFCU*(status: PayloadExecutionStatus): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus: PayloadStatusV1(status: status))

proc simpleFCU*(status: PayloadExecutionStatus, msg: string): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(payloadStatus: PayloadStatusV1(status: status, validationError: some(msg)))

proc validFCU*(id: Option[PayloadID], validHash: Hash256): ForkchoiceUpdatedResponse =
  ForkchoiceUpdatedResponse(
    payloadStatus: PayloadStatusV1(
      status: PayloadExecutionStatus.valid,
      latestValidHash: some(BlockHash validHash.data)
    ),
    payloadId: id
  )

proc invalidStatus*(validHash: Hash256, msg: string): PayloadStatusV1 =
  PayloadStatusV1(
    status: PayloadExecutionStatus.invalid,
    latestValidHash: some(BlockHash validHash.data),
    validationError: some(msg)
  )

proc toBlockBody*(payload: ExecutionPayloadV1): BlockBody =
  # TODO the transactions from the payload have to be converted here
  result.transactions.setLen(payload.transactions.len)
  for i, tx in payload.transactions:
    result.transactions[i] = rlp.decode(distinctBase tx, Transaction)
