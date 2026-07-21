# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import ssz_serialization, beacon_chain/spec/[eth2_merkleization, ssz_codec]

from beacon_chain/spec/datatypes/gloas import ExecutionPayload
from beacon_chain/spec/datatypes/electra import ExecutionRequests
from ../common/hardforks import BlobSchedule

export ssz_serialization, ssz_codec

# ---------------------------------------------------------------------------
# SSZ max-length constants
# ---------------------------------------------------------------------------

# As per spec:
# https://github.com/ethereum/execution-specs/blob/bd8c673552d957dbe9c9f3f2656b87201f5ae646/src/ethereum/forks/amsterdam/stateless_ssz.py#L41
#
# Not all consts are defined here as we get some of the types from beacon_chain datatypes

const
  MAX_BLOB_COMMITMENTS_PER_BLOCK* = 4096
  MAX_WITNESS_NODES* = 1 shl 22 # 2^22
  MAX_WITNESS_CODES* = 1 shl 18 # 2^18
  MAX_WITNESS_HEADERS* = 256
  MAX_BYTES_PER_CODE* = 1 shl 16 # 2^16
  MAX_BYTES_PER_HEADER* = 1 shl 10 # 2^10
  MAX_BYTES_PER_WITNESS_NODE* = 1 shl 10 # 2^10
  MAX_OPTIONAL_FORK_ACTIVATION_VALUES* = 1
  MAX_BLOB_SCHEDULES_PER_FORK* = 1
  MAX_PUBLIC_KEYS* = 1 shl 15 # 2^15
  PUBLIC_KEY_BYTES* = 65

  # Amsterdam SSZ stateless input schema identifier.
  STATELESS_INPUT_SCHEMA_ID* = 0x0001'u16
  STATELESS_INPUT_SCHEMA_ID_SIZE* = 2

  # We should be using the HardFork enum value for Amsterdam from hardforks.nim
  # but BPO1-BPO5 are already defined there, while in the execution-specs tag
  # tests-zkevm@v0.5.0 only BPO1-BPO2 is defined, making the enum value differ.
  # So we hardcode it here for now to the value of the specs/tests used.
  PROTOCOL_FORK_AMSTERDAM* = 20'u64

# ---------------------------------------------------------------------------
# SSZ container types
# ---------------------------------------------------------------------------

# As per spec:
# https://github.com/ethereum/execution-specs/blob/bd8c673552d957dbe9c9f3f2656b87201f5ae646/src/ethereum/forks/amsterdam/stateless_ssz.py#L96
#
# Not all types are defined here as we get some of the types from beacon_chain datatypes

type
  NewPayloadRequest* = object
    executionPayload*: ExecutionPayload
    versionedHashes*: List[Digest, MAX_BLOB_COMMITMENTS_PER_BLOCK]
    parentBeaconBlockRoot*: Digest
    executionRequests*: ExecutionRequests

  ExecutionWitness* = object
    state*: List[ByteList[MAX_BYTES_PER_WITNESS_NODE], MAX_WITNESS_NODES]
    codes*: List[ByteList[MAX_BYTES_PER_CODE], MAX_WITNESS_CODES]
    headers*: List[ByteList[MAX_BYTES_PER_HEADER], MAX_WITNESS_HEADERS]

  # Optional uint64 encoded as a List of 0 or 1 elements.
  ForkActivation* = object
    block_number*: List[uint64, MAX_OPTIONAL_FORK_ACTIVATION_VALUES]
    timestamp*: List[uint64, MAX_OPTIONAL_FORK_ACTIVATION_VALUES]

  # Optional BlobSchedule encoded as a List of 0 or 1 elements.
  ForkConfig* = object
    fork*: uint64
    activation*: ForkActivation
    blob_schedule*: List[BlobSchedule, MAX_BLOB_SCHEDULES_PER_FORK]

  # Note: named `StatelessChainConfig` to avoid name collision with EL `ChainConfig`
  StatelessChainConfig* = object
    chain_id*: uint64
    active_fork*: ForkConfig

  StatelessInput* = object
    new_payload_request*: NewPayloadRequest
    witness*: ExecutionWitness
    chain_config*: StatelessChainConfig
    public_keys*: List[ByteVector[PUBLIC_KEY_BYTES], MAX_PUBLIC_KEYS]

  StatelessValidationResult* = object
    new_payload_request_root*: Digest
    successful_validation*: bool
    chain_config*: StatelessChainConfig

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# https://github.com/ethereum/execution-specs/blob/bd8c673552d957dbe9c9f3f2656b87201f5ae646/src/ethereum/forks/amsterdam/stateless.py#L255
func compute_new_payload_request_root*(input: StatelessInput): Digest =
  ## Compute the request root for a stateless input via SSZ hash tree root.
  hash_tree_root(input.new_payload_request)
