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
  EVMForkToFork: array[FkCancun..FkLatest, HardFork] = [
    Cancun,
    Prague,
    Osaka,
  ]

# Should be based on timestamp and not on Fork after introduction 
# of BPO forks - EIP-7892 https://eips.ethereum.org/EIPS/eip-7892

func getMaxBlobsPerBlock*(com: CommonRef, timestamp: EthTime): uint64 =
  doAssert(com.isCancunOrLater(timestamp))
  com.maxBlobsPerBlock(timestamp)

func getBlobBaseFeeUpdateFraction*(com: CommonRef, timestamp: EthTime): uint64 =
  doAssert(com.isCancunOrLater(timestamp))
  com.baseFeeUpdateFraction(timestamp)
