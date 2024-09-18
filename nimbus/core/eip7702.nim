# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
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
  results,
  stew/assign2,
  eth/common/eth_types,
  eth/common/eth_types_rlp,
  eth/keys

const
  DelegationPrefix = [0xef.byte, 0x01, 0x00]
  Magic = 0x05

func authority*(auth: Authorization): Opt[EthAddress] =
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

func parseDelegation*(code: CodeBytesRef): bool =
  if code.len != 23:
    return false

  if not code.hasPrefix(DelegationPrefix):
    return false

  true

func addressToDelegation*(auth: EthAddress): array[23, byte] =
  assign(result.toOpenArray(0, 2), DelegationPrefix)
  assign(result.toOpenArray(3, 22), auth)

func parseDelegationAddress*(code: CodeBytesRef): Opt[EthAddress] =
  if code.len != 23:
    return Opt.none(EthAddress)

  if not code.hasPrefix(DelegationPrefix):
    return Opt.none(EthAddress)

  Opt.some(slice[20](code, 3, 22))
