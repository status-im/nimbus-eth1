# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./types,
  ./state,
  ./code_bytes,
  ../common/evmforks,
  ../utils/utils,
  ../db/ledger,
  ../core/eip7702

proc isCreate*(message: Message): bool =
  message.kind in {CallKind.Create, CallKind.Create2}

proc generateContractAddress*(vmState: BaseVMState,
                              sender: Address): Address =
  # `sender` is BAL tracked in `prepareToRunComputation`
  let creationNonce = vmState.readOnlyLedger().getNonce(sender)
  generateAddress(sender, creationNonce)

proc getCallCode*(vmState: BaseVMState, codeAddress: Address): CodeBytesRef =
  # `codeAddress` is BAL tracked in `initialAccessListEIP2929`
  let code = vmState.readOnlyLedger.getCode(codeAddress)
  if vmState.fork < FkPrague:
    return code

  let delegateTo = parseDelegationAddress(code).valueOr:
    return code

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(delegateTo)
  vmState.readOnlyLedger.getCode(delegateTo)
