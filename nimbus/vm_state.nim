# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./vm_compile_flags

when evmc0_enabled or vm0_enabled:
  import
    ./vm/state as vms
  export
    vms.setupTxContext

else:
  import
    ./vm2/state_transactions as vmx,
    ./vm2/state as vms
  export
    vmx.setupTxContext

export
  vms.`$`,
  vms.blockNumber,
  vms.blockhash,
  vms.buildWitness,
  vms.coinbase,
  vms.consensusEnginePoA,
  vms.difficulty,
  vms.disableTracing,
  vms.enableTracing,
  vms.gasLimit,
  vms.generateWitness,
  vms.`generateWitness=`,
  vms.getAncestorHash,
  vms.getAndClearLogEntries,
  vms.getTracingResult,
  vms.init,
  vms.mutateStateDB,
  vms.newAccessLogs,
  vms.newBaseVMState,
  vms.readOnlyStateDB,
  vms.removeTracedAccounts,
  vms.status,
  vms.`status=`,
  vms.timestamp,
  vms.tracedAccounts,
  vms.tracedAccountsPairs,
  vms.update,
  vms.updateBlockHeader

# End
