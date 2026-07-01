# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import ssz_serialization, beacon_chain/spec/ssz_codec

from beacon_chain/spec/datatypes/gloas import ExecutionPayload
from beacon_chain/spec/datatypes/electra import ExecutionRequests
from ../common/hardforks import BlobSchedule

export ssz_serialization, ssz_codec

# ---------------------------------------------------------------------------
# SSZ max-length constants
# ---------------------------------------------------------------------------

# As per spec:
# https://github.com/ethereum/execution-specs/blob/f03c2e0af2df95cd2eed029ba4ea7140acd028c7/src/ethereum/forks/amsterdam/stateless_ssz.py#L41
#
# Not all consts are defined here as we get some of the types from beacon_chain datatypes

const
  MAX_BLOB_COMMITMENTS_PER_BLOCK* = 4096
  MAX_WITNESS_NODES* = 1 shl 22 # 2^22
  MAX_WITNESS_CODES* = 1 shl 18 # 2^18
  MAX_WITNESS_HEADERS* = 256
  # Should be 2^16 but there are test vectors that violate this limit
  # MAX_BYTES_PER_CODE* = 1 shl 16            # 2^16
  MAX_BYTES_PER_CODE* = 1 shl 17 # 2^17
  MAX_BYTES_PER_HEADER* = 1 shl 10 # 2^10
  MAX_BYTES_PER_WITNESS_NODE* = 1 shl 10 # 2^10
  MAX_OPTIONAL_FORK_ACTIVATION_VALUES* = 1
  MAX_BLOB_SCHEDULES_PER_FORK* = 1
  MAX_PUBLIC_KEYS* = 1 shl 15 # 2^15
  PUBLIC_KEY_BYTES* = 65

  # Amsterdam SSZ stateless input schema identifier.
  STATELESS_INPUT_SCHEMA_ID* = 0x0001'u16
  STATELESS_INPUT_SCHEMA_ID_SIZE* = 2

# ---------------------------------------------------------------------------
# SSZ container types
# ---------------------------------------------------------------------------

# As per spec:
# https://github.com/ethereum/execution-specs/blob/f03c2e0af2df95cd2eed029ba4ea7140acd028c7/src/ethereum/forks/amsterdam/stateless_ssz.py#L96
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
