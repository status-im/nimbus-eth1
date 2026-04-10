# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import ssz_serialization

export ssz_serialization

type
  # https://github.com/ethereum/execution-specs/blob/e2ff4cc00ca94cb5872090e0f813894e231f6be3/src/ethereum/forks/amsterdam/stateless.py#L82
  StatelessChainConfig = object
    chain_id*: uint64

  # https://github.com/ethereum/execution-specs/blob/e2ff4cc00ca94cb5872090e0f813894e231f6be3/src/ethereum/forks/amsterdam/stateless.py#L126
  StatelessValidationResult* = object
    new_payload_request_root*: Digest
    successful_validation*: bool
    chain_config*: StatelessChainConfig
