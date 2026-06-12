# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../evm/code_bytes,
  ../constants,
  results,
  stew/assign2,
  eth/common/eth_types,
  eth/common/eth_types_rlp,
  eth/common/keys

const
  PER_AUTH_BASE_COST* = 12500
  PER_EMPTY_ACCOUNT_COST* = 25000

func authority*(auth: Authorization): Opt[Address] =
  const SECP256K1halfN = SECPK1_N div 2

  if auth.yParity > 1'u8:
    # auth.yParity must be 0 or 1
    return Opt.none(Address)

  if auth.s > SECP256K1halfN:
    # auth.s must be <= SECP256K1N/2
    return Opt.none(Address)

  let sigHash = rlpHashForSigning(auth)

  var bytes: array[65, byte]
  assign(bytes.toOpenArray(0, 31), auth.r.toBytesBE())
  assign(bytes.toOpenArray(32, 63), auth.s.toBytesBE())
  bytes[64] = auth.yParity.byte

  let sig = Signature.fromRaw(bytes).valueOr:
    return Opt.none(Address)

  let pubkey = recover(sig, SkMessage(sigHash.data)).valueOr:
    return Opt.none(Address)

  ok(pubkey.toCanonicalAddress())

func isDelegation*(code: openArray[byte]): bool =
  ## Returns true if `code` is a well-formed EIP-7702 delegation designator: the
  ## EIP7702_DELEGATION_PREFIX (0xef0100) followed by a 20-byte address, for
  ## EIP7702_DELEGATION_SIZE (23) bytes total.
  code.len == EIP7702_DELEGATION_SIZE and
    code[0] == EIP7702_DELEGATION_PREFIX[0] and
    code[1] == EIP7702_DELEGATION_PREFIX[1] and
    code[2] == EIP7702_DELEGATION_PREFIX[2]

template isDelegation*(code: CodeBytesRef): bool =
  isDelegation(code.bytes())

func addressToDelegation*(auth: Address): array[EIP7702_DELEGATION_SIZE, byte] =
  assign(result.toOpenArray(0, 2), EIP7702_DELEGATION_PREFIX)
  assign(result.toOpenArray(3, 22), auth.data)

func parseDelegationAddress*(code: CodeBytesRef): Opt[Address] =
  if not isDelegation(code.bytes()):
    return Opt.none(Address)

  Opt.some(Address(slice[20](code, 3, 22)))
