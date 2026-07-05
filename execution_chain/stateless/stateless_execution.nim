# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/tables,
  results,
  stew/endians2,
  eth/common/[headers, blocks, hashes],
  eth/trie/ordered_trie,
  beacon_chain/spec/eth2_merkleization,
  beacon_chain/spec/datatypes/constants,
  ../common/common,
  ../db/ledger,
  ../db/core_db/memory_only,
  ../evm/[types, state],
  ../core/executor/process_block,
  ../block_access_list/block_access_list_validation,
  ./[witness_types, witness_verification, stateless_types]

from beacon_chain/spec/datatypes/electra import
  DepositRequest, WithdrawalRequest, ConsolidationRequest
from beacon_chain/spec/datatypes/gloas import ExecutionPayload
from ../utils/utils import calcRequestsHash

export witness_types, stateless_types, common, headers, blocks, results

func toExecutionWitness*(w: ExecutionWitnessWithKeys): ExecutionWitness =
  var res: ExecutionWitness
  for node in w.state:
    discard res.state.add(ByteList[MAX_BYTES_PER_WITNESS_NODE].init(node))
  for code in w.codes:
    discard res.codes.add(ByteList[MAX_BYTES_PER_CODE].init(code))
  for header in w.headers:
    discard res.headers.add(ByteList[MAX_BYTES_PER_HEADER].init(header))
  res

proc statelessProcessBlock*(
    witness: ExecutionWitness, com: CommonRef, blk: Block
): Result[void, string] =
  let
    verifiedHeaders = ?witness.verifyHeaders(blk.header)
    parent = verifiedHeaders[^1] # The last header is the parent
    preStateRoot = parent.stateRoot

  # Convert the list of trie nodes into a table keyed by node hash.
  var nodes: Table[Hash32, seq[byte]]
  for n in witness.state:
    nodes[keccak256(n.asSeq())] = n.asSeq()

  # Create an empty in memory database.
  let
    memoryDb = newCoreDbRef(DefaultDbMemory)
    memoryTxFrame = memoryDb.baseTxFrame()
  defer:
    memoryDb.close()

  # Load the subtrie of trie nodes (both account and storage tries) into the
  # in memory database.
  memoryTxFrame.putSubtrie(preStateRoot, nodes).isOkOr:
    return err("Unable to load subtrie: " & $error)
  if memoryTxFrame.getStateRoot().get() != preStateRoot:
    return err("Witness subtrie state root mismatch")

  # Load the contract code into the database indexed by code hash.
  for c in witness.codes:
    doAssert memoryTxFrame.persistCodeByHash(keccak256(c.asSeq()), c.asSeq()).isOk()

  # Load the block hashes into the database indexed by block number.
  for h in verifiedHeaders:
    try:
      memoryTxFrame.addBlockNumberToHashLookup(h.number, h.computeRlpHash())
    except RlpError as e:
      raiseAssert e.msg

  # Create evm instance using the in memory database.
  let memoryVmState = BaseVMState()
  memoryVmState.init(
    parent, blk.header, com, memoryTxFrame, storeSlotHash = false,
    enableBalTracker = com.isAmsterdamOrLater(blk.header.timestamp),
    stateless = true)

  defer:
    memoryVmState.dispose()

  # Execute the block with all validations enabled
  ?memoryVmState.processBlock(
    blk,
    skipValidation = false,
    skipReceipts = false,
    skipUncles = true,
    skipStateRootCheck = false,
    skipPostExecBalCheck = not memoryVmState.balTrackerEnabled
  )
  doAssert memoryVmState.ledger.getStateRoot() == blk.header.stateRoot

  ok()

proc statelessProcessBlock*(
    witness: ExecutionWitness, id: NetworkId, config: ChainConfig, blk: Block
): Result[void, string] =
  let com =
    CommonRef.new(db = nil, config = config, networkId = id, initializeDb = false)
  statelessProcessBlock(witness, com, blk)

template statelessProcessBlock*(
    witness: ExecutionWitness, id: NetworkId, blk: Block
): Result[void, string] =
  statelessProcessBlock(witness, id, chainConfigForNetwork(id), blk)

# https://github.com/ethereum/execution-specs/blob/b6b764ff21bb754b79e11ef5dc7ad1f79996e923/src/ethereum/forks/amsterdam/execution_engine/validation_helpers.py#L22
func toBlock(
    p: ExecutionPayload, parentBeaconBlockRoot: Opt[Hash32], requestsHash: Opt[Hash32]
): Block {.raises: [RlpError].} =
  var txs = newSeqOfCap[Transaction](p.transactions.len)
  for tx in p.transactions:
    txs.add(rlp.decode(distinctBase(tx), Transaction)) # asSeq
  var wds = newSeqOfCap[Withdrawal](p.withdrawals.len)
  for wd in p.withdrawals:
    wds.add(
      Withdrawal(
        index: wd.index,
        validatorIndex: wd.validator_index,
        address: wd.address,
        amount: uint64(wd.amount),
      )
    )
  Block(
    header: Header(
      parentHash: Hash32(p.parent_hash.data),
      ommersHash: EMPTY_UNCLE_HASH,
      coinbase: p.fee_recipient,
      stateRoot: Hash32(p.state_root.data),
      transactionsRoot: orderedTrieRoot(txs),
      receiptsRoot: Hash32(p.receipts_root.data),
      logsBloom: Bloom(p.logs_bloom.data),
      difficulty: 0.u256,
      number: p.block_number,
      gasLimit: p.gas_limit,
      gasUsed: p.gas_used,
      timestamp: EthTime(p.timestamp),
      extraData: p.extra_data.asSeq(),
      mixHash: Bytes32(p.prev_randao.data),
      nonce: default(Bytes8),
      baseFeePerGas: Opt.some(p.base_fee_per_gas),
      withdrawalsRoot: Opt.some(orderedTrieRoot(wds)),
      blobGasUsed: Opt.some(p.blob_gas_used),
      excessBlobGas: Opt.some(p.excess_blob_gas),
      parentBeaconBlockRoot: parentBeaconBlockRoot,
      requestsHash: requestsHash,
      blockAccessListHash: Opt.some(keccak256(p.block_access_list.asSeq())),
      slotNumber: Opt.some(uint64(p.slot_number)),
    ),
    uncles: @[],
    transactions: txs,
    withdrawals: Opt.some(wds),
  )

func chainConfigForStateless(cc: StatelessChainConfig): ChainConfig =
  # Nimbus EVM needs the full fork timeline, but the stateless input only provides
  # the active fork. Set the rest to 0 to allow for execution. The active fork is
  # set to the provided values.
  let networkId = NetworkId(cc.chain_id.u256)

  var bs = defaultBlobSchedule()
  if cc.active_fork.blob_schedule.len > 0:
    bs[Amsterdam] = Opt.some(cc.active_fork.blob_schedule[0])

  let amsterdamTime =
    if cc.active_fork.activation.timestamp.len > 0:
      Opt.some(EthTime(cc.active_fork.activation.timestamp[0]))
    else:
      Opt.some(0.EthTime)

  ChainConfig(
    chainId: networkId,
    homesteadBlock: Opt.some(0.BlockNumber),
    eip150Block: Opt.some(0.BlockNumber),
    eip155Block: Opt.some(0.BlockNumber),
    eip158Block: Opt.some(0.BlockNumber),
    byzantiumBlock: Opt.some(0.BlockNumber),
    constantinopleBlock: Opt.some(0.BlockNumber),
    petersburgBlock: Opt.some(0.BlockNumber),
    istanbulBlock: Opt.some(0.BlockNumber),
    berlinBlock: Opt.some(0.BlockNumber),
    londonBlock: Opt.some(0.BlockNumber),
    posBlock: Opt.some(0.BlockNumber),
    shanghaiTime: Opt.some(0.EthTime),
    cancunTime: Opt.some(0.EthTime),
    pragueTime: Opt.some(0.EthTime),
    osakaTime: Opt.some(0.EthTime),
    bpo1Time: Opt.some(0.EthTime),
    bpo2Time: Opt.some(0.EthTime),
    bpo3Time: Opt.some(0.EthTime),
    bpo4Time: Opt.some(0.EthTime),
    bpo5Time: Opt.some(0.EthTime),
    amsterdamTime: amsterdamTime,
    blobSchedule: bs,
    # Inherit deposit contract address from the known network config
    # TODO: Separate out the deposit contract address code.
    depositContractAddress: chainConfigForNetwork(networkId).depositContractAddress,
  )

# Encode execution requests into EL format:
# https://github.com/ethereum/execution-specs/blob/b6b764ff21bb754b79e11ef5dc7ad1f79996e923/src/ethereum/forks/amsterdam/execution_engine/requests.py#L131
func encodeDeposits(
    deposits: List[DepositRequest, Limit MAX_DEPOSIT_REQUESTS_PER_PAYLOAD]
): seq[byte] =
  var res: seq[byte]
  for d in deposits:
    res.add(d.pubkey.blob)
    res.add(d.withdrawal_credentials.data)
    res.add(uint64(d.amount).toBytesLE())
    res.add(d.signature.blob)
    res.add(d.index.toBytesLE())
  res

func encodeWithdrawals(
    withdrawals: List[WithdrawalRequest, Limit MAX_WITHDRAWAL_REQUESTS_PER_PAYLOAD]
): seq[byte] =
  var res: seq[byte]
  for w in withdrawals:
    res.add(w.source_address.data)
    res.add(w.validator_pubkey.blob)
    res.add(uint64(w.amount).toBytesLE())
  res

func encodeConsolidations(
    consolidations:
      List[ConsolidationRequest, Limit MAX_CONSOLIDATION_REQUESTS_PER_PAYLOAD]
): seq[byte] =
  var res: seq[byte]
  for c in consolidations:
    res.add(c.source_address.data)
    res.add(c.source_pubkey.blob)
    res.add(c.target_pubkey.blob)
  res

proc executeNewPayload(input: StatelessInput): Result[void, string] =
  # TODO: implement validate_chain_config
  let
    reqs = input.new_payload_request.executionRequests
    requestsHash = Opt.some(
      calcRequestsHash(
        (DEPOSIT_REQUEST_TYPE, encodeDeposits(reqs.deposits)),
        (WITHDRAWAL_REQUEST_TYPE, encodeWithdrawals(reqs.withdrawals)),
        (CONSOLIDATION_REQUEST_TYPE, encodeConsolidations(reqs.consolidations)),
      )
    )
    parentBeaconBlockRoot =
      Opt.some(input.new_payload_request.parentBeaconBlockRoot.data.to(Hash32))
    blk =
      try:
        toBlock(
          input.new_payload_request.executionPayload, parentBeaconBlockRoot,
          requestsHash,
        )
      except RlpError as e:
        return err("Failed to decode execution payload: " & e.msg)

    com = CommonRef.new(
      db = nil,
      config = chainConfigForStateless(input.chain_config),
      networkId = NetworkId(input.chain_config.chain_id.u256),
      initializeDb = false,
    )

  # Early validation of the input BAL before execution, just like is done for the
  # stateful path. Rejects invalid BALs early without paying the cost of block execution.
  if com.isAmsterdamOrLater(blk.header.timestamp):
    let
      expectedBalHash = blk.header.blockAccessListHash.valueOr:
        return err("Post-Amsterdam block header must have blockAccessListHash")

      balBytes = input.new_payload_request.executionPayload.block_access_list.asSeq()
      bal: BlockAccessListRef = new BlockAccessList

    bal[] = BlockAccessList.decode(balBytes).valueOr:
      return err("Failed to decode block access list: " & error)
    ?bal.validate(expectedBalHash, blk.header.gasLimit)

  statelessProcessBlock(input.witness, com, blk)

# https://github.com/ethereum/execution-specs/blob/b6b764ff21bb754b79e11ef5dc7ad1f79996e923/src/ethereum/forks/amsterdam/stateless.py#L344
proc verify_stateless_new_payload*(input: StatelessInput): StatelessValidationResult =
  let new_payload_request_root = hash_tree_root(input.new_payload_request)

  StatelessValidationResult(
    new_payload_request_root: new_payload_request_root,
    successful_validation: executeNewPayload(input).isOk(),
    chain_config: input.chain_config,
  )
