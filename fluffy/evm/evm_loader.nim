# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import evmc/evmc

export evmc

# This is currently built using a manual build script which copies the library into the build directory
const libevmone* = "build/libevmone.so"

proc evmc_create_evmone(): ptr evmc_vm {.cdecl, importc: "evmc_create_evmone", raises: [], gcsafe, dynlib: libevmone.}

# Using evmone evm (for now)

const EVMC_ABI_VERSION* = 12

proc loadEvmcVM*(): ptr evmc_vm =
  evmc_create_evmone()
