# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  DelegationPrefix = [0xef.byte, 0x01, 0x00]

const
  PER_AUTH_BASE_COST* = 12500
  PER_EMPTY_ACCOUNT_COST* = 25000

func authority*(auth: Authorization): Opt[Address] =
  const SECP256K1halfN = SECPK1_N div 2

  if auth.v > 1'u64:
    # auth.v must be 0 or 1
    return Opt.none(Address)

  if auth.s > SECP256K1halfN:
    # auth.s must be <= SECP256K1N/2
    return Opt.none(Address)

  let sigHash = rlpHashForSigning(auth)

  var bytes: array[65, byte]
  assign(bytes.toOpenArray(0, 31), auth.r.toBytesBE())
  assign(bytes.toOpenArray(32, 63), auth.s.toBytesBE())
  bytes[64] = auth.v.byte

  let sig = Signature.fromRaw(bytes).valueOr:
    return Opt.none(Address)

  let pubkey = recover(sig, SkMessage(sigHash.data)).valueOr:
    return Opt.none(Address)

  ok(pubkey.toCanonicalAddress())

func parseDelegation*(code: CodeBytesRef): bool =
  if code.len != 23:
    return false

  if not code.hasPrefix(DelegationPrefix):
    return false

  true

func addressToDelegation*(auth: Address): array[23, byte] =
  assign(result.toOpenArray(0, 2), DelegationPrefix)
  assign(result.toOpenArray(3, 22), auth.data)

func parseDelegationAddress*(code: CodeBytesRef): Opt[Address] =
  if code.len != 23:
    return Opt.none(Address)

  if not code.hasPrefix(DelegationPrefix):
    return Opt.none(Address)

  Opt.some(Address(slice[20](code, 3, 22)))
