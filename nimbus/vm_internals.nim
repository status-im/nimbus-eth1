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

when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/memory as vmm
else:
  import
    ./vm2/memory as vmm
  
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


when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/interpreter/utils/utils_numeric as vmn
else:
  import
    ./vm2/interpreter/utils/utils_numeric as vmn

  
export
  vmn.GasNatural,
  vmn.calcMemSize,
  vmn.ceil32,
  vmn.cleanMemRef,
  vmn.log2,
  vmn.log256,
  vmn.rangeToPadded,
  vmn.rangeToPadded2,
  vmn.safeInt,
  vmn.setSign,
  vmn.toInt,
  vmn.wordCount


# Wrapping the wrapper -- lol
when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/interpreter as vmi
  export
    vmi

else:
  import
    ./vm2/code_stream as aCst,
    ./vm2/computation as bChp,
    ./vm2/interpreter_dispatch as cVmc,
    ./vm2/interpreter/gas_meter as eGmt,
    ./vm2/interpreter/op_codes as fVmo,
    ./vm2/message as gVmg,
    ./vm2/stack as hStk
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
    bChp.isSelfDestructed,
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
