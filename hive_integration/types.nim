# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common/[hashes],
  web3/execution_types

type
  ExecutableData* = object
    basePayload*      : ExecutionPayload
    attr*             : PayloadAttributes
    beaconRoot*       : Opt[Hash32]
    versionedHashes*  : Opt[seq[Hash32]]
    executionRequests*: Opt[seq[seq[byte]]]
