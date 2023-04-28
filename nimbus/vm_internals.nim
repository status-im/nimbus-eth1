# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# At the moment, this header file interface is only used for testing.

import
  ./evm/memory as vmm

export
  vmm.Memory,
  vmm.extend,
  vmm.len,
  vmm.newMemory,
  vmm.read,
  vmm.write

when defined(evmc_enabled):
  export
    vmm.readPtr

import
  ./evm/interpreter/utils/utils_numeric as vmn


export
  vmn.GasNatural,
  vmn.calcMemSize,
  vmn.ceil32,
  vmn.cleanMemRef,
  vmn.log2,
  vmn.log256,
  vmn.rangeToPadded,
  vmn.safeInt,
  vmn.setSign,
  vmn.toInt,
  vmn.wordCount


# Wrapping the wrapper -- lol
import
  ./evm/code_stream as aCst,
  ./evm/computation as bChp,
  ./evm/interpreter_dispatch as cVmc,
  ./evm/interpreter/gas_meter as eGmt,
  ./evm/interpreter/op_codes as fVmo,
  ./evm/message as gVmg,
  ./evm/stack as hStk
export
  aCst.CodeStream,
  aCst.`$`,
  aCst.`[]`,
  aCst.atEnd,
  aCst.decompile,
  aCst.displayDecompiled,
  aCst.hasSStore,
  aCst.isValidOpcode,
  aCst.items,
  aCst.len,
  aCst.newCodeStream,
  aCst.newCodeStreamFromUnescaped,
  aCst.next,
  aCst.peek,
  aCst.read,
  aCst.readVmWord,
  aCst.updatePc,
  bChp.accountExists,
  bChp.addLogEntry,
  bChp.chainTo,
  bChp.commit,
  bChp.dispose,
  bChp.fork,
  bChp.getBalance,
  bChp.getBlockHash,
  bChp.getBlockNumber,
  bChp.getChainId,
  bChp.getCode,
  bChp.getCodeHash,
  bChp.getCodeSize,
  bChp.getCoinbase,
  bChp.getDifficulty,
  bChp.getGasLimit,
  bChp.getGasPrice,
  bChp.getGasRefund,
  bChp.getOrigin,
  bChp.getStorage,
  bChp.getTimestamp,
  bChp.isError,
  bChp.isOriginComputation,
  bChp.isSuccess,
  bChp.merge,
  bChp.newComputation,
  bChp.prepareTracer,
  bChp.refundSelfDestruct,
  bChp.rollback,
  bChp.selfDestruct,
  bChp.setError,
  bChp.shouldBurnGas,
  bChp.snapshot,
  bChp.traceError,
  bChp.traceOpCodeEnded,
  bChp.traceOpCodeStarted,
  bChp.tracingEnabled,
  bChp.writeContract,
  cVmc.execCallOrCreate,
  cVmc.executeOpcodes,
  eGmt.consumeGas,
  eGmt.init,
  eGmt.refundGas,
  eGmt.returnGas,
  fVmo.Op,
  fVmo.PrevRandao,
  gVmg.isCreate,
  hStk.Stack,
  hStk.`$`,
  hStk.`[]`,
  hStk.dup,
  hStk.len,
  hStk.newStack,
  hStk.peek,
  hStk.peekInt,
  hStk.popAddress,
  hStk.popInt,
  hStk.popTopic,
  hStk.push,
  hStk.swap,
  hStk.top

# End
