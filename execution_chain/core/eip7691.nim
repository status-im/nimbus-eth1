# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../constants,
  ../common/hardforks,
  ../common/common

func getMaxBlobsPerBlock*(com: CommonRef, fork: HardFork): uint64 =
  if fork < Cancun:
    return 0
  com.maxBlobsPerBlock(fork)

func getTargetBlobsPerBlock*(com: CommonRef, fork: HardFork): uint64 =
  if fork < Cancun:
    return 0
  com.targetBlobsPerBlock(fork)

func getBlobBaseFeeUpdateFraction*(com: CommonRef, fork: HardFork): uint64 =
  if fork < Cancun:
    return 0
  com.baseFeeUpdateFraction(fork)

func getMaxBlobGasPerBlock*(com: CommonRef, fork: HardFork): uint64 =
  com.getMaxBlobsPerBlock(fork) * GAS_PER_BLOB
