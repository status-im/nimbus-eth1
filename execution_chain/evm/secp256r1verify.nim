# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  bearssl/secp256r1_verify as ec,
  stew/assign2

type
  EcPublicKey* = object
    buf: array[65, byte]
    pk: ec.EcPublicKey

func initRaw*(_: type EcPublicKey, data: openArray[byte]): EcPublicKey =
  result.buf[0] = 4.byte
  assign(result.buf.toOpenArray(1, 64), data)
  result.pk.curve = EC_secp256r1
  result.pk.q = result.buf[0].addr
  result.pk.qlen = 65
  
proc isInfinityByte*(data: openArray[byte]): bool =
  ## Check if all values in ``data`` are zero.
  for b in data:
    if b != 0:
      return false
  return true

func verifyRaw*(sig: openArray[byte], hash: openArray[byte], pk: EcPublicKey): bool =
  secp256r1_i31_vrfy_raw(
    hash[0].addr,
    hash.len.uint,
    pk.pk.addr,
    sig[0].addr,
    sig.len.uint) == 1
