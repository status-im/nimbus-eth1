# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
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
                              kind: CallKind,
                              sender: Address,
                              salt = ZERO_CONTRACTSALT,
                              code = CodeBytesRef(nil)): Address =
  if kind == CallKind.Create:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(sender)
    let creationNonce = vmState.readOnlyLedger().getNonce(sender)
    generateAddress(sender, creationNonce)
  else:
    generateSafeAddress(sender, salt, code.bytes)

proc getCallCode*(vmState: BaseVMState, codeAddress: Address): CodeBytesRef =
  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(codeAddress)

  let isPrecompile = getPrecompile(vmState.fork, codeAddress).isSome()
  if isPrecompile:
    return CodeBytesRef(nil)

  if vmState.fork >= FkPrague:
    if vmState.balTrackerEnabled:
      let
        code = vmState.readOnlyLedger.getCode(codeAddress)
        delegateTo = parseDelegationAddress(code)
      if delegateTo.isSome():
        vmState.balTracker.trackAddressAccess(delegateTo.get())
    vmState.readOnlyLedger.resolveCode(codeAddress)
  else:
    vmState.readOnlyLedger.getCode(codeAddress)
