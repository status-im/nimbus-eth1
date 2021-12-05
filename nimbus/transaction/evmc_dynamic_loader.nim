# Nimbus - Dynamic loader for EVM modules as shared libraries / DLLs
#
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#{.push raises: [Defect].}

import
  std/[dynlib, strformat, strutils, os],
  chronicles,
  evmc/evmc, ../config

# The built-in Nimbus EVM, via imported C function.
proc evmc_create_nimbus_evm(): ptr evmc_vm {.cdecl, importc.}

# Import this module to pull in the definition of `evmc_create_nimbus_evm`.
# Nim thinks the module is unused because the function is only called via
# `.exportc` -> `.importc`.
{.warning[UnusedImport]: off.}:
  import ./evmc_vm_glue

var evmcLibraryPath {.threadvar.}: string
  ## Library path set by `--evm` command line option.
  ## Like the loaded EVMs themselves, this is thread-local for Nim simplicity.

proc evmcSetLibraryPath*(path: string) =
  evmcLibraryPath = path

proc evmcLoadVMGetCreateFn(): (evmc_create_vm_name_fn, string) =
  var path = evmcLibraryPath
  if path.len == 0:
    path = getEnv("NIMBUS_EVM")

  # Use built-in EVM if no other is specified.
  if path.len == 0:
    return (evmc_create_nimbus_evm, "built-in")

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

  # Load the library.
  let lib = loadLib(path, false)
  if lib.isNil:
    warn "Error loading EVM library", path
    return (nil, "")

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
  var sym = symAddr(lib, symbolName)
  if sym.isNil:
    const fallback = "evmc_create"
    sym = symAddr(lib, fallback)
    if sym.isNil:
      warn "EVMC create function not found in library", path
      warn "Tried this library symbol", symbol=symbolName
      warn "Tried this library symbol", symbol=fallback
      return (nil, "")

  return (cast[evmc_create_vm_name_fn](sym), path)

proc evmcLoadVMShowDetail(): ptr evmc_vm =
  let (vmCreate, vmDescription) = evmcLoadVMGetCreateFn()
  if vmCreate.isNil:
    return nil

  {.gcsafe.}:
    let vm: ptr evmc_vm = vmCreate()

  if vm.isNil:
    warn "The loaded EVM did not create a VM when requested",
      `from`=vmDescription
    return nil

  if vm.abi_version != EVMC_ABI_VERSION:
    warn "The loaded EVM is for an incompatible EVMC ABI",
      requireABI=EVMC_ABI_VERSION, loadedABI=vm.abi_version,
      `from`=vmDescription
    warn "The loaded EVM will not be used", `from`=vmDescription
    return nil

  let name = if vm.name.isNil: "<nil>" else: $vm.name
  let version = if vm.version.isNil: "<nil>" else: $vm.version
  info "Using EVM", name=name, version=version, `from`=vmDescription
  return vm

proc evmcLoadVMCached*(): ptr evmc_vm =
  # TODO: Make this open the VM library once per process.  Currently it does
  # so once per thread, but at least this is thread-safe.
  var vm {.threadvar.}: ptr evmc_vm
  var triedLoading {.threadvar.}: bool
  if not triedLoading:
    triedLoading = true
    vm = evmcLoadVMShowDetail()
  return vm
