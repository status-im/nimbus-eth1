# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# see vm_opcode_value
import
  ./interpreter/opcode_values as vmo
export
  vmo.Op, vmo.PrevRandao


# see vm_message
import
  ./message as vmm
export
  vmm.isCreate

# Used in vm_types. Beware of recursive dependencies

# see vm_computation
import
  ./computation as vmc
export
  vmc.accountExists,
  vmc.addLogEntry,
  vmc.commit,
  vmc.dispose,
  vmc.execCallOrCreate,
  vmc.chainTo,
  vmc.execSelfDestruct,
  vmc.executeOpcodes,
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
