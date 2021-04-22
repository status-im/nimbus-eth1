# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.


# The computation module suffers from a circular include/import dependency.
# After fixing this wrapper should be re-factored.
when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/computation as vmc

  export
    vmc.accountExists,
    vmc.addLogEntry,
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
    vmc.getOrigin,
    vmc.getStorage,
    vmc.getTimestamp,
    vmc.selfDestruct,
    vmc.setError,
    vmc.prepareTracer,
    vmc.traceOpCodeEnded,
    vmc.traceOpCodeStarted,
    vmc.tracingEnabled

else:
  import
    ./vm2/compu_helper as xmc,
    ./vm2/computation as vmc

  export
    xmc.accountExists,
    xmc.addLogEntry,
    xmc.execSelfDestruct,
    xmc.fork,
    xmc.getBalance,
    xmc.getBlockHash,
    xmc.getBlockNumber,
    xmc.getChainId,
    xmc.getCode,
    xmc.getCodeHash,
    xmc.getCodeSize,
    xmc.getCoinbase,
    xmc.getDifficulty,
    xmc.getGasLimit,
    xmc.getGasPrice,
    xmc.getOrigin,
    xmc.getStorage,
    xmc.getTimestamp,
    xmc.prepareTracer,
    xmc.selfDestruct,
    xmc.setError,
    xmc.traceOpCodeEnded,
    xmc.traceOpCodeStarted,
    xmc.tracingEnabled

export
  vmc.commit,
  vmc.dispose,
  vmc.execCallOrCreate,
  vmc.chainTo,
  vmc.executeOpcodes,
  vmc.getGasRefund,
  vmc.isError,
  vmc.isOriginComputation,
  vmc.isSuccess,
  vmc.isSuicided,
  vmc.merge,
  vmc.newComputation,
  vmc.refundSelfDestruct,
  vmc.rollback,
  vmc.shouldBurnGas,
  vmc.snapshot,
  vmc.traceError,
  vmc.writeContract

# End
