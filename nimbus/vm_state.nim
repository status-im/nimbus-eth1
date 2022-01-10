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
    # ./vm/types, # legacy -- newBaseVMState() below
    ./vm/state as vms
  export
    vms.setupTxContext

else:
  import
    # ./vm2/types, # legacy -- newBaseVMState() below
    ./vm2/state_transactions as vmx,
    ./vm2/state as vms
  export
    vmx.setupTxContext

export
  vms.`$`,
  vms.blockNumber,
  vms.buildWitness,
  vms.coinbase,
  vms.consensusEnginePoA,
  vms.difficulty,
  vms.disableTracing,
  vms.enableTracing,
  vms.baseFee,
  vms.generateWitness,
  vms.`generateWitness=`,
  vms.getAncestorHash,
  vms.getAndClearLogEntries,
  vms.getTracingResult,
  vms.legacyInit,
  vms.mutateStateDB,
  vms.new,
  vms.readOnlyStateDB,
  vms.removeTracedAccounts,
  vms.status,
  vms.`status=`,
  vms.tracedAccounts,
  vms.tracedAccountsPairs

#[
import db/[accounts_cache, db_chain], eth/common
proc init*(
      self:        BaseVMState;
      ac:          AccountsCache;   ## accounts cache synced with parent
      header:      BlockHeader;     ## child header _after_ insertion point
      chainDB:     BaseChainDB;     ## block chain database
      tracerFlags: set[TracerFlags] = {})
    {.gcsafe,
      deprecated: "use BaseVMState.new() for creating a VM envirionment",
      raises: [Defect,CatchableError].} =
  ## Legacy function, usage of which should be tapered out.
  self.legacyInit(ac, header, chainDB, tracerFlags)

proc newBaseVMState*(ac: AccountsCache, header: BlockHeader,
                     chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}):
                       BaseVMState
    {.gcsafe,
      deprecated: "use BaseVMState.new() for creating a VM envirionment",
      raises: [Defect,CatchableError].} =
  ## Legacy function, usage of which should be tapered out.
  new result
  result.legacyInit(ac, header, chainDB, tracerFlags)
#]#

# End
