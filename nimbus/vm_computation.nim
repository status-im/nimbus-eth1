# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./evm/computation as vmc,
  ./evm/interpreter_dispatch as vmi
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
  vmc.isSuccess,
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
  vmc.writeContract,
  vmc.evmcStatus,
  vmc.errorOpt

# End
