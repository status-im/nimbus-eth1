# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./evm/state_transactions as vmx,
  ./evm/state as vms
export
  vmx.setupTxContext

export
  vms.`$`,
  vms.blockNumber,
  vms.coinbase,
  vms.determineFork,
  vms.difficultyOrPrevRandao,
  vms.baseFeePerGas,
  vms.forkDeterminationInfoForVMState,
  vms.collectWitnessData,
  vms.`collectWitnessData=`,
  vms.getAncestorHash,
  vms.getAndClearLogEntries,
  vms.init,
  vms.mutateStateDB,
  vms.new,
  vms.reinit,
  vms.readOnlyStateDB,
  vms.status,
  vms.`status=`,
  vms.tracingEnabled,
  vms.captureTxStart,
  vms.captureTxEnd,
  vms.captureStart,
  vms.captureEnd,
  vms.captureEnter,
  vms.captureExit,
  vms.captureOpStart,
  vms.captureGasCost,
  vms.captureOpEnd,
  vms.captureFault,
  vms.capturePrepare

# End
