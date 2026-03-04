# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}
import
  eth/common/base

const
  STATE_BYTES_PER_NEW_ACCOUNT* = 112
  STATE_BYTES_PER_AUTH_BASE* = 23
  REGULAR_PER_AUTH_BASE_COST* = 7500
  STATE_BYTES_PER_STORAGE_SET* = 32

func stateGasPerByte*(gasLimit: GasInt): GasInt =
  return 1174.GasInt
