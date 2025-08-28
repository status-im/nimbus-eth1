# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

import
  stew/endians2

from eth/common/base import ForkID

type
  ChainForkId* = object
    forkHash*: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext*: uint64         # The RLP encoding must be variable-length

func to*(id: ChainForkId, _: type ForkID): ForkID =
  (uint32.fromBytesBE(id.forkHash), id.forkNext)

func to*(id: ForkID, _: type ChainForkId): ChainForkId =
  ChainForkId(
    forkHash: id.crc.toBytesBE,
    forkNext: id.nextFork
  )

