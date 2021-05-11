# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.


# The VM computation module suffers from a circular include/import dependency.
# After fixing this wrapper should be re-factored.
when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/computation as vmc
  export
    vmc.execCallOrCreate,
    vmc.executeOpcodes

else:
  import
    ./vm2/computation as vmc,
    ./vm2/interpreter_dispatch as vmi
  export
    vmi.execCallOrCreate,
    vmi.executeOpcodes

export
  vmc.accountExists,
  vmc.addLogEntry,
  vmc.chainTo,
  vmc.commit,
  vmc.dispose,
  vmc.execSelfDestruct,
  vmc.fork,
  vmc.getBalance,
  vmc.getBlockHash,
  vmc.getBlockNumber,
  vmc.getChainId,
  vmc.getCode,
  vmc.getCodeHash,
  vmc.getCodeSize,
  vmc.getCoinbase,
  vmc.getDifficulty,
  vmc.getGasLimit,
  vmc.getGasPrice,
  vmc.getGasRefund,
  vmc.getOrigin,
  vmc.getStorage,
  vmc.getTimestamp,
  vmc.isError,
  vmc.isOriginComputation,
  vmc.isSuccess,
  vmc.isSelfDestructed,
  vmc.merge,
  vmc.newComputation,
  vmc.prepareTracer,
  vmc.refundSelfDestruct,
  vmc.rollback,
  vmc.selfDestruct,
  vmc.setError,
  vmc.shouldBurnGas,
  vmc.snapshot,
  vmc.traceError,
  vmc.traceOpCodeEnded,
  vmc.traceOpCodeStarted,
  vmc.tracingEnabled,
  vmc.writeContract

# End
