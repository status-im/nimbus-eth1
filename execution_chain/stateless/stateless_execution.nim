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
  ../block_access_list/bal_validation,
  ./[witness_types, witness_verification, stateless_types]

from beacon_chain/spec/datatypes/electra import
  DepositRequest, WithdrawalRequest, ConsolidationRequest
from beacon_chain/spec/datatypes/gloas import
  ExecutionPayload, BuilderDepositRequest, BuilderExitRequest
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
    parent,
    blk.header,
    com,
    memoryTxFrame,
    storeSlotHash = false,
    enableBalTracker = com.isAmsterdamOrLater(blk.header.timestamp),
    stateless = true,
  )

  defer:
    memoryVmState.dispose()

  # Execute the block with all validations enabled
  ?memoryVmState.processBlock(
    blk,
    skipValidation = false,
    skipReceipts = false,
    skipUncles = true,
    skipStateRootCheck = false,
    skipPostExecBalCheck = not memoryVmState.balTrackerEnabled,
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

# https://github.com/ethereum/execution-specs/blob/4e7a7177242c3ab3dbc3525c3395933e907d7416/src/ethereum/forks/amsterdam/execution_engine/validation_helpers.py#L1
func toBlock(
    p: ExecutionPayload, parentBeaconBlockRoot: Opt[Hash32], requestsHash: Opt[Hash32]
): Block {.raises: [RlpError].} =
  var txs = newSeqOfCap[Transaction](p.transactions.len)
  for tx in p.transactions:
    txs.add(rlp.decode(distinctBase(tx), Transaction))

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

# https://github.com/ethereum/execution-specs/blob/4e7a7177242c3ab3dbc3525c3395933e907d7416/src/ethereum/forks/amsterdam/execution_engine/new_payload.py#L50
func is_valid_versioned_hashes(
    expected: openArray[Digest], blk: Block
): Result[void, string] =
  ## Return ok if and only if the versioned hashes computed by blob
  ## transactions in `new_payload_request.execution_payload` match
  ## `new_payload_request.versioned_hashes`.
  var versionedHashes: seq[VersionedHash]
  for tx in blk.transactions:
    if tx.txType == TxEip4844:
      versionedHashes.add(tx.versionedHashes)

  if versionedHashes.len != expected.len:
    return err("Versioned hashes count does not match the payload")

  for i, x in expected:
    if x.data != versionedHashes[i].data:
      return err("Versioned hash at index " & $i & " does not match the payload")

  ok()

func chainConfigForStateless(chainId: uint64): ChainConfig =
  # Normally `chainConfigForNetwork` would be used, but the stateless tests run
  # the guest fork from genesis, so every fork up to it is activated at zero.
  # TODO: Might have to change this system once the fork gets scheduled.
  const lastFork = HardFork.Amsterdam

  var transitions: ForkTransitionTable
  for f in low(HardFork) .. lastPurelyBlockNumberBasedFork:
    transitions.blockNumberThresholds[f] = Opt.some(0.BlockNumber)
  transitions.mergeForkTransitionThreshold.number = Opt.some(0.BlockNumber)
  transitions.mergeForkTransitionThreshold.ttd = Opt.some(0.u256)
  for f in firstTimeBasedFork .. lastFork:
    transitions.timeThresholds[f] = Opt.some(0.EthTime)

  let
    networkId = NetworkId(chainId.u256)
    config = ChainConfig(
      chainId: networkId,
      blobSchedule: defaultBlobSchedule(),
      # Inherit deposit contract address from the known network config
      # TODO: Separate out the deposit contract address code.
      depositContractAddress: chainConfigForNetwork(networkId).depositContractAddress,
    )
  config.populateFromForkTransitionTable(transitions)

  config

# Encode execution requests into EL format:
# https://github.com/ethereum/execution-specs/blob/4e7a7177242c3ab3dbc3525c3395933e907d7416/src/ethereum/forks/amsterdam/execution_engine/requests.py#L108
func encodeDeposits(deposits: seq[DepositRequest]): seq[byte] =
  var res: seq[byte]
  for d in deposits:
    res.add(d.pubkey.blob)
    res.add(d.withdrawal_credentials.data)
    res.add(uint64(d.amount).toBytesLE())
    res.add(d.signature.blob)
    res.add(d.index.toBytesLE())
  res

func encodeWithdrawals(withdrawals: seq[WithdrawalRequest]): seq[byte] =
  var res: seq[byte]
  for w in withdrawals:
    res.add(w.source_address.data)
    res.add(w.validator_pubkey.blob)
    res.add(uint64(w.amount).toBytesLE())
  res

func encodeConsolidations(consolidations: seq[ConsolidationRequest]): seq[byte] =
  var res: seq[byte]
  for c in consolidations:
    res.add(c.source_address.data)
    res.add(c.source_pubkey.blob)
    res.add(c.target_pubkey.blob)
  res

func encodeBuilderDeposits(deposits: seq[BuilderDepositRequest]): seq[byte] =
  var res: seq[byte]
  for d in deposits:
    res.add(d.pubkey.blob)
    res.add(d.withdrawal_credentials.data)
    res.add(uint64(d.amount).toBytesLE())
    res.add(d.signature.blob)
  res

func encodeBuilderExits(exits: seq[BuilderExitRequest]): seq[byte] =
  var res: seq[byte]
  for e in exits:
    res.add(e.source_address.data)
    res.add(e.pubkey.blob)
  res

proc executeNewPayload(input: StatelessInput): Result[void, string] =
  let
    reqs = input.new_payload_request.executionRequests
    requestsHash = Opt.some(
      calcRequestsHash(
        (DEPOSIT_REQUEST_TYPE, encodeDeposits(reqs.deposits)),
        (WITHDRAWAL_REQUEST_TYPE, encodeWithdrawals(reqs.withdrawals)),
        (CONSOLIDATION_REQUEST_TYPE, encodeConsolidations(reqs.consolidations)),
        (BUILDER_DEPOSIT_REQUEST_TYPE, encodeBuilderDeposits(reqs.builder_deposits)),
        (BUILDER_EXIT_REQUEST_TYPE, encodeBuilderExits(reqs.builder_exits)),
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
      config = chainConfigForStateless(input.chain_id),
      networkId = NetworkId(input.chain_id.u256),
      initializeDb = false,
    )

  ?is_valid_versioned_hashes(input.new_payload_request.versionedHashes, blk)

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

# https://github.com/ethereum/execution-specs/blob/4e7a7177242c3ab3dbc3525c3395933e907d7416/src/ethereum/forks/amsterdam/stateless.py#L229
proc verify_stateless_new_payload*(input: StatelessInput): StatelessValidationResult =
  let new_payload_request_root = compute_new_payload_request_root(input)

  StatelessValidationResult(
    new_payload_request_root: new_payload_request_root,
    successful_validation: executeNewPayload(input).isOk(),
    chain_id: input.chain_id,
    schema_id: STATELESS_INPUT_SCHEMA_ID,
  )
