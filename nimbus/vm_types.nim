# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/types as vmt
else:
  import
    ./vm2/types as vmt

export
  vmt.BaseVMState,
  vmt.CallKind,
  vmt.Computation,
  vmt.Error,
  vmt.GasMeter,
  vmt.Message,
  vmt.MsgFlags,
  vmt.TracerFlags,
  vmt.TransactionTracer,
  vmt.VMFlag

when defined(evmc_enabled):
  import
    ./vm/evmc_api as evmc
  export
    evmc.HostContext,
    evmc.accountExists,
    evmc.call,
    evmc.copyCode,
    evmc.emitLog,
    evmc.getBalance,
    evmc.getBlockHash,
    evmc.getCodeHash,
    evmc.getCodeSize,
    evmc.getStorage,
    evmc.getTxContext,
    evmc.init,
    evmc.nim_create_nimbus_vm,
    evmc.nim_host_create_context,
    evmc.nim_host_destroy_context,
    evmc.nim_host_get_interface,
    evmc.nimbus_host_interface,
    evmc.nimbus_message,
    evmc.nimbus_result,
    evmc.nimbus_tx_context,
    evmc.selfDestruct,
    evmc.setStorage

# End
