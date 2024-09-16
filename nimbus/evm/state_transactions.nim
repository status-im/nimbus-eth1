# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  stew/assign2,
  ../constants,
  ../db/ledger,
  ./computation,
  ./interpreter_dispatch,
  ./message,
  ./state,
  ./types,
  ./interpreter/gas_meter,
  eth/common/eth_types_rlp,
  eth/keys

{.push raises: [].}

const
  DelegationPrefix = [0xef.byte, 0x01, 0x00]
  Magic = 0x05

func authority(auth: Authorization): Opt[EthAddress] =
  var w = initRlpWriter()
  w.appendRawBytes([Magic.byte])
  w.append(auth.chainId.uint64)
  w.append(auth.address)
  w.append(auth.nonce)
  let sigHash = keccakHash(w.finish())

  var bytes: array[65, byte]
  assign(bytes.toOpenArray(0, 31), auth.R.toBytesBE())
  assign(bytes.toOpenArray(32, 63), auth.S.toBytesBE())
  bytes[64] = auth.y_parity.byte

  let sig = Signature.fromRaw(bytes).valueOr:
    return Opt.none(EthAddress)

  let pubkey = recover(sig, SkMessage(sigHash.data)).valueOr:
    return Opt.none(EthAddress)

  ok(pubkey.toCanonicalAddress())

func parseDelegation(code: CodeBytesRef): bool =
  if code.len != 23:
    return false

  if not code.hasPrefix(DelegationPrefix):
    return false

  true

func addressToDelegation(auth: EthAddress): array[23, byte] =
  assign(result.toOpenArray(0, 2), DelegationPrefix)
  assign(result.toOpenArray(3, 22), auth)

# Using `proc` as `incNonce()` might be `proc` in logging mode
proc preExecComputation(c: Computation) =
  if not c.msg.isCreate:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)

  # EIP-7702
  for auth in c.authorizationList:
    # 1. Verify the chain id is either 0 or the chain's current ID.
    if not(auth.chainId == 0.ChainId or auth.chainId == c.vmState.com.chainId):
      continue

    # 2. authority = ecrecover(keccak(MAGIC || rlp([chain_id, address, nonce])), y_parity, r, s]
    let authority = authority(auth).valueOr:
      continue

    # 3. Add authority to accessed_addresses (as defined in EIP-2929.)
    let ledger = c.vmState.stateDB
    ledger.accessList(authority)

    # 4. Verify the code of authority is either empty or already delegated.
    let code = ledger.getCode(authority)
    if code.len > 0:
      if not parseDelegation(code):
        continue

    # 5. Verify the nonce of authority is equal to nonce.
    if ledger.getNonce(authority) != auth.nonce:
      continue

    # 6. Add PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST gas to the global refund counter if authority exists in the trie.
    if ledger.accountExists(authority):
      const
        PER_AUTH_BASE_COST = 2500
        PER_EMPTY_ACCOUNT_COST = 25000
      c.gasMeter.refundGas(PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST)

    # 7. Set the code of authority to be 0xef0100 || address. This is a delegation designation.
    ledger.setCode(authority, @(addressToDelegation(authority)))

    # 8. Increase the nonce of authority by one.
    ledger.setNonce(authority, auth.nonce + 1)

proc postExecComputation(c: Computation) =
  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
  c.vmState.status = c.isSuccess

proc execComputation*(c: Computation) =
  c.preExecComputation()
  c.execCallOrCreate()
  c.postExecComputation()

template execSysCall*(c: Computation) =
  # A syscall to EVM doesn't require
  # a pre or post ceremony
  c.execCallOrCreate()
