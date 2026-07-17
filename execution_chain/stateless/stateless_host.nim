# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  results,
  secp256k1,
  stew/[endians2, sequtils2],
  eth/common/[blocks, eth_types_rlp, hashes, keys, transaction_utils],
  ./stateless_types

from beacon_chain/spec/datatypes/gloas import ExecutionPayload
from beacon_chain/spec/datatypes/electra import ExecutionRequests
from beacon_chain/spec/datatypes/capella import Withdrawal
from beacon_chain/spec/datatypes/bellatrix import BloomLogs
from beacon_chain/spec/datatypes/base import Gwei
from beacon_chain/spec/beacon_time import Slot
from beacon_chain/spec/presets import
  MAX_BYTES_PER_TRANSACTION, MAX_EXTRA_DATA_BYTES, MAX_TRANSACTIONS_PER_PAYLOAD,
  MAX_WITHDRAWALS_PER_PAYLOAD

export stateless_types, results

## Stateless host interfaces
## Spec:
## https://github.com/ethereum/execution-specs/blob/e5a8caf1b8055e4d805c7fb169edfa710914b7da/src/ethereum/forks/amsterdam/stateless_host.py#L1

## https://github.com/ethereum/execution-specs/blob/e5a8caf1b8055e4d805c7fb169edfa710914b7da/src/ethereum/forks/amsterdam/transactions.py#L810
func recover_transaction_public_key*(
    tx: Transaction
): Opt[ByteVector[PUBLIC_KEY_BYTES]] =
  ## Recover the canonical uncompressed SEC1 public key for a transaction.
  ##
  ## Returns `none` for an invalid signature.
  let key = tx.recoverKey().valueOr:
    return Opt.none(ByteVector[PUBLIC_KEY_BYTES])
  # Use the secp256k1 serialization as it has the full uncompressed
  # SEC1 form. PublicKey.toRaw (nim-eth) strips the 0x04 prefix.
  Opt.some(ByteVector[PUBLIC_KEY_BYTES](SkPublicKey(key).toRaw()))

func serialize_stateless_input*(stateless_input: StatelessInput): seq[byte] =
  ## Serialize a StatelessInput to schema-prefixed SSZ bytes.
  let encoded = SSZ.encode(stateless_input)
  var res = newSeqOfCap[byte](STATELESS_INPUT_SCHEMA_ID_SIZE + encoded.len)
  res.write(STATELESS_INPUT_SCHEMA_ID.toBytesBE())
  res.write(encoded)
  res

func deserialize_stateless_output*(
    data: openArray[byte]
): Result[StatelessValidationResult, string] =
  ## Deserialize a StatelessValidationResult from guest output bytes.
  try:
    ok(SSZ.decode(data, StatelessValidationResult))
  except SerializationError as e:
    err("Failed to deserialize StatelessValidationResult: " & e.msg)

func build_chain_config*(chain_id: uint64): StatelessChainConfig =
  ## Build the chain configuration supported by this host.
  ##
  ## For now the Amsterdam stateless host only describes the Amsterdam fork.
  StatelessChainConfig(
    chain_id: chain_id,
    active_fork: ForkConfig(
      activation: ForkActivation(
        block_number: List[uint64, MAX_OPTIONAL_FORK_ACTIVATION_VALUES].init(@[]),
        timestamp: List[uint64, MAX_OPTIONAL_FORK_ACTIVATION_VALUES].init(@[0'u64]),
      )
    ),
  )

func build_stateless_input*(
    blk: Block,
    execution_witness: ExecutionWitness,
    execution_requests: ExecutionRequests,
    block_access_list: openArray[byte], # already RLP-encoded
    chain_id: uint64,
): Result[StatelessInput, string] =
  ## Build a StatelessInput from a completed block.
  ##
  ## Extract the header, transactions, and withdrawals from the block,
  ## compute the block hash, collect versioned hashes, and package
  ## everything into a StatelessInput ready for stateless guest execution.
  ##
  ## The block is assumed to be validated: block validity keeps extraData,
  ## transactions, withdrawals and the access list well under the payload's
  ## SSZ list limits.
  template header(): Header =
    blk.header

  let
    base_fee_per_gas = header.baseFeePerGas.valueOr:
      return err("Post-Amsterdam block header must have baseFeePerGas")
    blob_gas_used = header.blobGasUsed.valueOr:
      return err("Post-Amsterdam block header must have blobGasUsed")
    excess_blob_gas = header.excessBlobGas.valueOr:
      return err("Post-Amsterdam block header must have excessBlobGas")
    parent_beacon_block_root = header.parentBeaconBlockRoot.valueOr:
      return err("Post-Amsterdam block header must have parentBeaconBlockRoot")
    slot_number = header.slotNumber.valueOr:
      return err("Post-Amsterdam block header must have slotNumber")
  if blk.withdrawals.isNone:
    return err("Post-Amsterdam block body must have withdrawals")

  let block_hash = header.computeBlockHash

  # Encode transactions to bytes, recover public keys, and collect the
  # versioned hashes.
  var
    transactions = newSeqOfCap[bellatrix.Transaction](blk.transactions.len)
    public_keys: List[ByteVector[PUBLIC_KEY_BYTES], MAX_PUBLIC_KEYS]
    versioned_hashes: List[Digest, MAX_BLOB_COMMITMENTS_PER_BLOCK]
  for tx in blk.transactions:
    transactions.add(bellatrix.Transaction.init(rlp.encode(tx)))

    let public_key = recover_transaction_public_key(tx).valueOr:
      # Skip transactions without a recoverable key (invalid signature values).
      # This is similar to the spec where they skip transactions that fail to
      # decode. However, our block already holds the decoded transaction objects,
      # so invalid signature is the only failure that can occur here still.
      continue
    if not public_keys.add(public_key):
      return err("Too many public keys for the stateless input")

    if tx.txType == TxEip4844:
      for versioned_hash in tx.versionedHashes:
        if not versioned_hashes.add(Digest(data: versioned_hash.data)):
          return err("Too many versioned hashes for the payload request")

  var withdrawals = newSeqOfCap[capella.Withdrawal](blk.withdrawals.get.len)
  for withdrawal in blk.withdrawals.get:
    withdrawals.add(
      capella.Withdrawal(
        index: withdrawal.index,
        validator_index: withdrawal.validatorIndex,
        address: withdrawal.address,
        amount: Gwei(withdrawal.amount),
      )
    )

  let payload = ExecutionPayload(
    parent_hash: Digest(data: header.parentHash.data),
    fee_recipient: header.coinbase,
    state_root: Digest(data: header.stateRoot.data),
    receipts_root: Digest(data: header.receiptsRoot.data),
    logs_bloom: BloomLogs(data: header.logsBloom.data),
    prev_randao: Digest(data: header.mixHash.data),
    block_number: header.number,
    gas_limit: header.gasLimit,
    gas_used: header.gasUsed,
    timestamp: uint64(header.timestamp),
    extra_data: List[byte, MAX_EXTRA_DATA_BYTES].init(header.extraData),
    base_fee_per_gas: base_fee_per_gas,
    block_hash: Digest(data: block_hash.data),
    transactions:
      List[bellatrix.Transaction, MAX_TRANSACTIONS_PER_PAYLOAD].init(transactions),
    withdrawals: List[capella.Withdrawal, MAX_WITHDRAWALS_PER_PAYLOAD].init(withdrawals),
    blob_gas_used: blob_gas_used,
    excess_blob_gas: excess_blob_gas,
    block_access_list: List[byte, MAX_BYTES_PER_TRANSACTION].init(@block_access_list),
    slot_number: Slot(slot_number),
  )

  let new_payload = NewPayloadRequest(
    executionPayload: payload,
    versionedHashes: versioned_hashes,
    parentBeaconBlockRoot: Digest(data: parent_beacon_block_root.data),
    executionRequests: execution_requests,
  )

  ok(
    StatelessInput(
      new_payload_request: new_payload,
      witness: execution_witness,
      chain_config: build_chain_config(chain_id),
      public_keys: public_keys,
    )
  )

func verify_new_payload_request_root*(
    input: StatelessInput, output: StatelessValidationResult
): Result[void, string] =
  ## Host-side root check: it must match the locally computed root of the
  ## submitted payload request, confirming the guest ran on the correct input.
  if output.new_payload_request_root != compute_new_payload_request_root(input):
    err("Stateless output root does not match the submitted payload request")
  else:
    ok()
