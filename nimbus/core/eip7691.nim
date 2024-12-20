# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../constants

func getMaxBlobGasPerBlock*(electra: bool): uint64 =
  if electra: MAX_BLOB_GAS_PER_BLOCK_ELECTRA.uint64
  else: MAX_BLOB_GAS_PER_BLOCK.uint64

func getTargetBlobGasPerBlock*(electra: bool): uint64 =
  if electra: TARGET_BLOB_GAS_PER_BLOCK_ELECTRA.uint64
  else: TARGET_BLOB_GAS_PER_BLOCK.uint64

func getBlobBaseFeeUpdateFraction*(electra: bool): uint64 =
  if electra: BLOB_BASE_FEE_UPDATE_FRACTION_ELECTRA.uint64
  else: BLOB_BASE_FEE_UPDATE_FRACTION.uint64

func getMaxBlobsPerBlock*(electra: bool): uint64 =
  if electra: MAX_BLOBS_PER_BLOCK_ELECTRA.uint64
  else: MAX_BLOBS_PER_BLOCK.uint64
