# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  ../common/evmforks,
  ../common/common

const
  EVMForkToFork: array[FkCancun..FkLatest, HardFork] = [
    Cancun,
    Prague,
    Osaka,
  ]

func getMaxBlobsPerBlock*(com: CommonRef, fork: EVMFork): uint64 =
  doAssert(fork >= FkCancun)
  com.maxBlobsPerBlock(EVMForkToFork[fork])

func getMaxBlobGasPerBlock*(com: CommonRef, fork: EVMFork): uint64 =
  doAssert(fork >= FkCancun)
  com.getMaxBlobsPerBlock(fork) * GAS_PER_BLOB

func getTargetBlobsPerBlock*(com: CommonRef, fork: EVMFork): uint64 =
  doAssert(fork >= FkCancun)
  com.targetBlobsPerBlock(EVMForkToFork[fork])

func getBlobBaseFeeUpdateFraction*(com: CommonRef, fork: EVMFork): uint64 =
  doAssert(fork >= FkCancun)
  com.baseFeeUpdateFraction(EVMForkToFork[fork])
