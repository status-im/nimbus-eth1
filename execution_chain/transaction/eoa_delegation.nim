# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/sets,
  eth/common/transactions,
  results,
  ../common/common,
  ../evm/[types, state, evm_errors, internals],
  ../db/ledger,
  ../core/[eip4844, eip7702, eip8037],
   ./call_types

proc validateAuthorization(auth: Authorization, vmState: BaseVMState): Opt[addresses.Address] =
  # 1. Verify the chain id is either 0 or the chain's current ID.
  if not(auth.chainId == 0.u256 or auth.chainId == vmState.com.chainId):
    return Opt.none(addresses.Address)

  # 2. Verify the nonce is less than 2**64 - 1.
  if auth.nonce+1 < auth.nonce:
    return Opt.none(addresses.Address)

  # 3. authority = ecrecover(keccak(MAGIC || rlp([chain_id, address, nonce])), y_parity, r, s]
  let authority = authority(auth).valueOr:
    return Opt.none(addresses.Address)

  # 4. Add authority to accessed_addresses (as defined in EIP-2929.)
  let
    ledger = vmState.ledger
  ledger.accessList(authority)

  # 5. Verify the code of authority is either empty or already delegated.
  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(authority)
  let
    code = ledger.getCode(authority)
  if code.len > 0:
    if not isDelegation(code):
      return Opt.none(addresses.Address)

  # 6. Verify the nonce of authority is equal to nonce.
  if ledger.getNonce(authority) != auth.nonce:
    return Opt.none(addresses.Address)

  Opt.some(authority)

proc setDelegation*(call: CallParams): int64 =
  var
    executionRefund = 0'i64

  let
    vmState = call.vmState
    ledger = vmState.ledger

  # EIP-7702
  for auth in call.authorizationList:
    let authority = auth.validateAuthorization(vmState).valueOr:
      continue

    # 7. Add PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST gas to the global refund counter if authority exists in the trie.
    if ledger.accountExists(authority):
      executionRefund += PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST

    # 8. Set the code of authority to be 0xef0100 || address. This is a delegation designation.
    let authCode =
      if auth.address == zeroAddress:
        @[]
      else:
        @(addressToDelegation(auth.address))

    ledger.setCode(authority, authCode)

    # 9. Increase the nonce of authority by one.
    ledger.setNonce(authority, auth.nonce + 1)

  executionRefund

proc setDelegation*(call: CallParams, c: Computation): EvmResultVoid =
  var
    writtenAccounts: HashSet[addresses.Address]
    delegationSetFor: HashSet[addresses.Address]

  writtenAccounts.incl call.sender

  if call.value.isZero.not:
    writtenAccounts.incl call.to

  let
    vmState = call.vmState
    ledger = vmState.ledger

  # Authorities a delegation was set for earlier in this transaction.
  for auth in call.authorizationList:
    let authority = auth.validateAuthorization(vmState).valueOr:
      continue

    if not ledger.accountExists(authority):
      ? c.gasMeter.chargeStateGas(CREATE_ACCOUNT_STATE_GAS, "setDelegation new account")

    if authority notin writtenAccounts:
      ? c.gasMeter.consumeGas(ACCOUNT_WRITE_8038, "setDelegation account write")
      writtenAccounts.incl authority

    let
      code = ledger.getOriginalCode(authority)
      delegatedBeforeTx = isDelegation(code)

    let authCode =
      if auth.address == zeroAddress:
        @[]
      else:
        if not delegatedBeforeTx and authority notin delegationSetFor:
          ? c.gasMeter.chargeStateGas(AUTH_BASE_STATE_GAS, "setDelegation auth base")
        delegationSetFor.incl authority
        @(addressToDelegation(auth.address))

    if vmState.balTrackerEnabled:
      vmState.balTracker.trackCodeChange(authority, authCode)
    ledger.setCode(authority, authCode)

    if vmState.balTrackerEnabled:
      vmState.balTracker.trackNonceChange(authority, auth.nonce + 1)
    ledger.setNonce(authority, auth.nonce + 1)
  ok()
