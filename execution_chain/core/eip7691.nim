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

func getMaxBlobGasPerBlock*(electra: bool): uint64 =
  if electra: MAX_BLOB_GAS_PER_BLOCK_ELECTRA.uint64
  else: MAX_BLOB_GAS_PER_BLOCK.uint64

func getTargetBlobGasPerBlock*(electra: bool): uint64 =
  if electra: TARGET_BLOB_GAS_PER_BLOCK_ELECTRA.uint64
  else: TARGET_BLOB_GAS_PER_BLOCK.uint64

const
  EVMForkToFork: array[FkCancun..EVMFork.high, HardFork] = [
    Cancun,
    Prague,
    Osaka
  ]

func getMaxBlobsPerBlock*(com: CommonRef, fork: EVMFork): uint64 =
  doAssert(fork >= FkCancun)
  com.maxBlobsPerBlock(EVMForkToFork[fork])

func getBlobBaseFeeUpdateFraction*(com: CommonRef, fork: EVMFork): uint64 =
  doAssert(fork >= FkCancun)
  com.baseFeeUpdateFraction(EVMForkToFork[fork])
