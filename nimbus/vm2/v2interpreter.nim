# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

when defined(evmc_enabled):
  {.fatal: "Flags \"evmc_enabled\" and \"vm2_enabled\" are mutually exclusive"}

# see vm_internals

import
  ./interpreter/op_codes as vmo
export
  vmo.Op


import
  ./interpreter/forks_list as vmf
export
  vmf.Fork


import
  ./v2message as vmm
export
  vmm.isCreate

# Used in vm_types. Beware of recursive dependencies

import
  ./compu_helper as xmc
export
  xmc.accountExists,
  xmc.addLogEntry,
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

import
  ./v2computation as vmc
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


import
  ./interpreter/gas_meter as gmt
export
  gmt.consumeGas,
  gmt.init,
  gmt.refundGas,
  gmt.returnGas


import
  ./code_stream as cst
export
  cst.CodeStream,
  cst.`$`,
  cst.newCodeStream,
  cst.newCodeStreamFromUnescaped,
  cst.read,
  cst.readVmWord,
  cst.len,
  cst.next,
  cst.items,
  cst.`[]`,
  cst.peek,
  cst.updatePc,
  cst.isValidOpcode,
  cst.decompile,
  cst.displayDecompiled,
  cst.hasSStore,
  cst.atEnd


import
  ./stack_defs as sdf,
  ./stack as stk
export
  sdf.Stack,
  stk.`$`,
  stk.`[]`,
  stk.dup,
  stk.len,
  stk.newStack,
  stk.peek,
  stk.peekInt,
  stk.popAddress,
  stk.popInt,
  stk.popTopic,
  stk.push,
  stk.swap,
  stk.top

# End
