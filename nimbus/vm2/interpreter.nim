# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.


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
  ./message as vmm
export
  vmm.isCreate

# Used in vm_types. Beware of recursive dependencies

import
  ./compu_helper as xmc
export
  xmc.accountExists,
  xmc.addLogEntry,
  xmc.chainTo,
  xmc.commit,
  xmc.dispose,
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
  xmc.getGasRefund,
  xmc.getOrigin,
  xmc.getStorage,
  xmc.getTimestamp,
  xmc.isError,
  xmc.isOriginComputation,
  xmc.isSuccess,
  xmc.isSuicided,
  xmc.merge,
  xmc.newComputation,
  xmc.prepareTracer,
  xmc.refundSelfDestruct,
  xmc.rollback,
  xmc.selfDestruct,
  xmc.setError,
  xmc.shouldBurnGas,
  xmc.snapshot,
  xmc.traceError,
  xmc.traceOpCodeEnded,
  xmc.traceOpCodeStarted,
  xmc.tracingEnabled,
  xmc.writeContract


import
  ./computation as vmc
export
  vmc.execCallOrCreate,
  vmc.executeOpcodes


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
  ./stack as stk
export
  stk.Stack,
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
