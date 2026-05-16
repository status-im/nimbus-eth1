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
  ./precompiles,
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
  let isPrecompile = getPrecompile(vmState.fork, codeAddress).isSome()
  if isPrecompile:
    return CodeBytesRef(nil)

  # `codeAddress` is BAL tracked in `initialAccessListEIP2929`
  var resolvedAddress = codeAddress
  if vmState.fork >= FkPrague:
    let
      code = vmState.readOnlyLedger.getCode(codeAddress)
      delegateTo = parseDelegationAddress(code)
    if delegateTo.isSome():
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackAddressAccess(delegateTo.value)
      resolvedAddress = delegateTo.value
  vmState.readOnlyLedger.getCode(resolvedAddress)
