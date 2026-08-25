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

from beacon_chain/spec/datatypes/gloas import ExecutionPayload, ExecutionRequests

export ssz_serialization, ssz_codec

# ---------------------------------------------------------------------------
# SSZ max-length constants
# ---------------------------------------------------------------------------

# As per spec:
# https://github.com/ethereum/execution-specs/blob/57d9170a27a3a7558e67d05d1418a178e6a8a31e/src/ethereum/forks/amsterdam/stateless_ssz.py#L42
#
# Not all consts are defined here as we get some of the types from beacon_chain datatypes

const
  MAX_WITNESS_HEADERS* = 256
  MAX_BYTES_PER_CODE* = 1 shl 16 # 2^16
  MAX_BYTES_PER_HEADER* = 1 shl 10 # 2^10
  MAX_BYTES_PER_WITNESS_NODE* = 1 shl 10 # 2^10
  MAX_OPTIONAL_FORK_ACTIVATION_VALUES* = 1
  PUBLIC_KEY_BYTES* = 65

  # We should be using the HardFork enum value for Amsterdam from hardforks.nim
  # but BPO1-BPO5 are already defined there, while in the execution-specs tag
  # tests-zkevm@v0.5.0 only BPO1-BPO2 is defined. Making the enum value different.
  # So we hardcode it here for now to the value of the specs/tests used, matching
  # the execution-specs ProtocolFork IntEnum value used to build the schema id.
  PROTOCOL_FORK_AMSTERDAM* = 0x15'u16
  STATELESS_INPUT_SCHEMA_REVISION* = 0x01'u16

  # Stateless guest input bytes are schema-prefixed: schema_id || encoded_payload
  STATELESS_INPUT_SCHEMA_ID* =
    (PROTOCOL_FORK_AMSTERDAM shl 8) or STATELESS_INPUT_SCHEMA_REVISION
  STATELESS_INPUT_SCHEMA_ID_SIZE* = 2

# ---------------------------------------------------------------------------
# SSZ container types
# ---------------------------------------------------------------------------

# As per spec:
# https://github.com/ethereum/execution-specs/blob/57d9170a27a3a7558e67d05d1418a178e6a8a31e/src/ethereum/forks/amsterdam/stateless_ssz.py#L74
#
# Not all types are defined here as we get some of the types from beacon_chain datatypes

type
  NewPayloadRequest* = object
    executionPayload*: ExecutionPayload
    versionedHashes*: seq[Digest]
    parentBeaconBlockRoot*: Digest
    executionRequests*: ExecutionRequests

  ExecutionWitness* = object
    state*: seq[ByteList[MAX_BYTES_PER_WITNESS_NODE]]
    codes*: seq[ByteList[MAX_BYTES_PER_CODE]]
    headers*: List[ByteList[MAX_BYTES_PER_HEADER], MAX_WITNESS_HEADERS]

  StatelessInput* = object
    new_payload_request*: NewPayloadRequest
    witness*: ExecutionWitness
    chain_id*: uint64
    public_keys*: seq[ByteVector[PUBLIC_KEY_BYTES]]

  StatelessValidationResult* = object
    new_payload_request_root*: Digest
    successful_validation*: bool
    chain_id*: uint64
    schema_id*: uint16

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# https://github.com/ethereum/execution-specs/blob/4e7a7177242c3ab3dbc3525c3395933e907d7416/src/ethereum/forks/amsterdam/stateless.py#L183
func compute_new_payload_request_root*(input: StatelessInput): Digest =
  ## Compute the request root for a stateless input via SSZ hash tree root.
  hash_tree_root(input.new_payload_request)
