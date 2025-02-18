# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[dynlib, strutils, os],
  evmc/evmc,
  chronicles

export evmc

const SUPPORTED_EVMC_ABI_VERSION = 12

# The steps below match the EVMC Loader documentation, copied here:
#
# - The filename is used to guess the EVM name and the name of the create
#   function. The create function name is constructed by the following
#   rules. Consider example path: "/ethereum/libexample-interpreter.so.1.0".
# - The filename is taken from the path: "libexample-interpreter.so.1.0".
# - The "lib" prefix and all file extensions are stripped from the name:
#   "example-interpreter".
# - All "-" are replaced with "_" to construct base name:
#   "example_interpreter"
# - The function name "evmc_create_" + base name is searched in the library:
#   "evmc_create_example_interpreter",
# - If the function is not found, the function name "evmc_create" is searched
#   in the library.
proc getEvmcCreateFn(path: string): evmc_create_vm_name_fn =
  doAssert(path.len() > 0)

  # Load the library.
  let lib = loadLib(path, false)
  if lib.isNil:
    warn "Error loading EVM library", path
    return nil

  # Find filename in the path.
  var symbolName = os.extractFilename(path)
  # Skip "lib" prefix if present.  Note, `removePrefix` only removes at the
  # start despite its documentation.
  symbolName.removePrefix("lib")
  # Trim all file extesnsions.  (`os.splitFile` only removes the last.)
  symbolName = symbolName.split('.', 1)[0]
  # Replace all "-" with "_".
  symbolName = symbolName.replace('-', '_')

  # Search for the built function name.
  symbolName = "evmc_create_" & symbolName
  var sym = symAddr(lib, symbolName.cstring)
  if sym.isNil:
    const fallback = "evmc_create"
    sym = symAddr(lib, fallback)
    if sym.isNil:
      warn "EVMC create function not found in library", path
      warn "Tried this library symbol", symbol=symbolName
      warn "Tried this library symbol", symbol=fallback
      return nil

  return cast[evmc_create_vm_name_fn](sym)

proc loadEvmcVM*(evmPath: string): ptr evmc_vm =
  let createFn = getEvmcCreateFn(evmPath)
  doAssert(not createFn.isNil())

  let vmPtr = createFn()
  doAssert(not vmPtr.isNil())
  doAssert(vmPtr.abi_version.int == SUPPORTED_EVMC_ABI_VERSION)

  return vmPtr
