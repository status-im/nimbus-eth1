# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import ../../nimbus/transaction/evmc_vm_glue

when not defined(evmc_enabled):
  {.
    error:
      "The Fluffy EVM requires evmc to be enabled. Compile with the -d:evmc_enabled flag."
  .}

type FluffyEvmRef* = ref object
  vmPtr: ptr evmc_vm

func init(T: type FluffyEvmRef): T =
  FluffyEvmRef(vmPtr: evmc_create_nimbus_evm())

func isClosed*(evm: FluffyEvmRef): bool =
  evm.vmPtr.isNil()

proc close(evm: FluffyEvmRef) =
  if not evm.vmPtr.isNil():
    evm.vmPtr.destroy(evm.vmPtr)
    evm.vmPtr = nil

#   desProc(vm)
# proc create_evm*() =
#   let vm = evmc_create_nimbus_evm()
#   echo "vm.abi_version: ", vm.abi_version
#   echo "vm.name: ", vm.name
#   echo "vm.version: ", vm.version
#   echo "vm.destroy: ", vm.destroy.isNil()
#   echo "vm.execute: ", vm.execute.isNil()

#   # let vm = (ref evmc_vm)(
#   #   abi_version:      EVMC_ABI_VERSION,
#   #   name:             evmcName,
#   #   version:          evmcVersion,
#   #   destroy:          evmcDestroy,
#   #   execute:          evmcExecute,
#   #   get_capabilities: evmcGetCapabilities,
#   #   set_option:       evmcSetOption
#   # )

#   let desProc = vm.destroy
#   desProc(vm)

when isMainModule:
  let evm = FluffyEvmRef.init()

  echo evm.isClosed()
  evm.close()
  echo evm.isClosed()
  evm.close()
