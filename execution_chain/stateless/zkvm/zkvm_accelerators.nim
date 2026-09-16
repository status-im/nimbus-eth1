# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import std/[os, strutils], stew/[assign2, ptrops]

## zkVM cryptographic accelerator interface
##
## Spec: https://github.com/eth-act/zkevm-standards `standards/c-interface-accelerators`
##
## The zkVM implements these primitives natively, at a fraction of the proving
## cost of the same computation expressed in RISC-V.
##
## TODO: bind the rest. The header also declares secp256k1_verify and
## bls12-381, which the guest currently computes in RISC-V.
##
## Every function returns `ZKVM_EOK` or `ZKVM_EFAIL`, but which of the two a
## bad *input* gets is per function: secp256r1 reports a rejected signature as
## `verified = false` with `ZKVM_EOK`, while bn254 reports a point off the
## curve as `ZKVM_EFAIL`, the same status as a broken accelerator. Each wrapper
## below says which it is.
##
## This module is only the binding: the link decides who implements the symbols.

# Location of the zkvm-standards' `zkvm_accelerators.h`
const zkvmAccelDir =
  currentSourcePath.rsplit({DirSep, AltSep}, 1)[0] &
  "/../../../vendor/zkevm-standards/standards/c-interface-accelerators"

# quoteShell is not defined when compiling to bare metal
when not defined(`any`) and not defined(standalone):
  {.passc: "-I" & quoteShell(zkvmAccelDir).}
else:
  {.passc: "-I\"" & zkvmAccelDir & "\"".}

const zkvmAccelHdr = "zkvm_accelerators.h"

type
  ZkvmStatus = cint

  # importc so these *are* the header's types rather than Nim look-alikes. A
  # plain Nim object is a different struct type and the generated call does not
  # compile. It also puts the header's _Alignas(8) in charge of where locals
  # land, which is what the accelerators read a word at a time.
  ZkvmBytes16 {.importc: "zkvm_bytes_16", header: zkvmAccelHdr.} = object
    data: array[16, byte]

  ZkvmBytes32 {.importc: "zkvm_bytes_32", header: zkvmAccelHdr.} = object
    data: array[32, byte]

  ZkvmBytes48 {.importc: "zkvm_bytes_48", header: zkvmAccelHdr.} = object
    data: array[48, byte]

  ZkvmBytes64 {.importc: "zkvm_bytes_64", header: zkvmAccelHdr.} = object
    data: array[64, byte]

  ZkvmBytes128 {.importc: "zkvm_bytes_128", header: zkvmAccelHdr.} = object
    data: array[128, byte]

  ZkvmBn254PairingPair {.importc: "zkvm_bn254_pairing_pair", header: zkvmAccelHdr.} = object
    g1: ZkvmBytes64
    g2: ZkvmBytes128

# Only success needs a name: the header defines any non-zero as failure.
const ZKVM_EOK = ZkvmStatus(0)

# ------------------------------------------------------------------------------
# Bindings, one per header declaration
# ------------------------------------------------------------------------------

proc c_zkvm_sha256(
  data: ptr byte, len: csize_t, output: ptr ZkvmBytes32
): ZkvmStatus {.importc: "zkvm_sha256", header: zkvmAccelHdr.}

proc c_zkvm_ripemd160(
  data: ptr byte, len: csize_t, output: ptr ZkvmBytes32
): ZkvmStatus {.importc: "zkvm_ripemd160", header: zkvmAccelHdr.}

proc c_zkvm_keccak256(
  data: ptr byte, len: csize_t, output: ptr ZkvmBytes32
): ZkvmStatus {.importc: "zkvm_keccak256", header: zkvmAccelHdr.}

proc c_zkvm_secp256k1_ecrecover(
  msg: ptr ZkvmBytes32, sig: ptr ZkvmBytes64, recid: uint8, output: ptr ZkvmBytes64
): ZkvmStatus {.importc: "zkvm_secp256k1_ecrecover", header: zkvmAccelHdr.}

proc c_zkvm_modexp(
  base: ptr byte,
  base_len: csize_t,
  exp: ptr byte,
  exp_len: csize_t,
  modulus: ptr byte,
  mod_len: csize_t,
  output: ptr byte,
): ZkvmStatus {.importc: "zkvm_modexp", header: zkvmAccelHdr.}

proc c_zkvm_secp256r1_verify(
  msg: ptr ZkvmBytes32,
  sig: ptr ZkvmBytes64,
  pubkey: ptr ZkvmBytes64,
  verified: ptr bool,
): ZkvmStatus {.importc: "zkvm_secp256r1_verify", header: zkvmAccelHdr.}

proc c_zkvm_bn254_g1_add(
  p1: ptr ZkvmBytes64, p2: ptr ZkvmBytes64, output: ptr ZkvmBytes64
): ZkvmStatus {.importc: "zkvm_bn254_g1_add", header: zkvmAccelHdr.}

proc c_zkvm_bn254_g1_mul(
  point: ptr ZkvmBytes64, scalar: ptr ZkvmBytes32, output: ptr ZkvmBytes64
): ZkvmStatus {.importc: "zkvm_bn254_g1_mul", header: zkvmAccelHdr.}

proc c_zkvm_bn254_pairing(
  pairs: ptr ZkvmBn254PairingPair, num_pairs: csize_t, verified: ptr bool
): ZkvmStatus {.importc: "zkvm_bn254_pairing", header: zkvmAccelHdr.}

proc c_zkvm_blake2f(
  rounds: uint32, h: ptr ZkvmBytes64, m: ptr ZkvmBytes128, t: ptr ZkvmBytes16, f: uint8
): ZkvmStatus {.importc: "zkvm_blake2f", header: zkvmAccelHdr.}

proc c_zkvm_kzg_point_eval(
  commitment: ptr ZkvmBytes48,
  z: ptr ZkvmBytes32,
  y: ptr ZkvmBytes32,
  proof: ptr ZkvmBytes48,
  verified: ptr bool,
): ZkvmStatus {.importc: "zkvm_kzg_point_eval", header: zkvmAccelHdr.}

# ------------------------------------------------------------------------------
# Nim-facing wrappers
#
# Named to match the modules they stand in for, so selecting a backend is an
# import rather than a change at every call site.
#
# Where the header uses the aligned struct types rather than raw pointers, the
# arguments have to be locals of those types, hence the copies below. Casting a
# calldata slice instead would skip the copy but hand the accelerator whatever
# alignment that offset happened to land on.
#
# The header also states every pointer must be valid and that a NULL pointer
# should panic, but `baseAddr` returns nil for an empty openArray. The `empty`
# local variable stands in for those.
# ------------------------------------------------------------------------------

proc sha256Into*(data: openArray[byte], output: var array[32, byte]) =
  ## Hash `data` into `output`.
  var
    res: ZkvmBytes32
    empty: byte

  doAssert c_zkvm_sha256(
    (if data.len > 0: baseAddr(data) else: addr empty), csize_t(data.len), addr res
  ) == ZKVM_EOK, "zkvm_sha256 failed"

  output = res.data

proc ripemd160Into*(data: openArray[byte], output: var array[32, byte]) =
  ## Hash `data` into `output`: the 20-byte digest lands in bytes 12..31 and
  ## bytes 0..11 are zeroed.
  ##
  ## Bound but unused: ZisK has no RIPEMD-160 state machine, so the vendor's
  ## implementation proves as ordinary RISC-V in the same way as ours.
  ## `precompiles.nim` keeps nimcrypto until some target has one.
  var
    res: ZkvmBytes32
    empty: byte

  doAssert c_zkvm_ripemd160(
    (if data.len > 0: baseAddr(data) else: addr empty), csize_t(data.len), addr res
  ) == ZKVM_EOK, "zkvm_ripemd160 failed"

  output = res.data

proc keccak256Into*(data: openArray[byte], output: var array[32, byte]) =
  ## Hash `data` into `output`.
  var
    res: ZkvmBytes32
    empty: byte

  doAssert c_zkvm_keccak256(
    (if data.len > 0: baseAddr(data) else: addr empty), csize_t(data.len), addr res
  ) == ZKVM_EOK, "zkvm_keccak256 failed"

  output = res.data

proc ecRecoverRaw*(
    msgHash: openArray[byte],
    sig: openArray[byte],
    recid: byte,
    output: var array[64, byte],
): bool =
  ## Recover the public key that signed `msgHash` from the signature `sig`, the
  ## big-endian `r ‖ s`. `output` receives the key's coordinates `x ‖ y`, which
  ## is the uncompressed SEC1 form without its leading `0x04`.
  ##
  ## `false` also covers a rejected signature, not just a failed accelerator:
  ## the vendor validates `r`, `s` and `recid` and reports both the same way.
  if msgHash.len != 32 or sig.len != 64:
    return false

  var
    msgBuf: ZkvmBytes32
    sigBuf, keyBuf: ZkvmBytes64
  assign(msgBuf.data, msgHash)
  assign(sigBuf.data, sig)

  if c_zkvm_secp256k1_ecrecover(addr msgBuf, addr sigBuf, uint8(recid), addr keyBuf) !=
      ZKVM_EOK:
    return false

  output = keyBuf.data
  true

proc modExpInto*(b, e, m: openArray[byte], output: var openArray[byte]) =
  ## `output = b^e mod m`, big-endian, with `output.len == m.len`.
  if output.len == 0:
    return
  doAssert output.len == m.len, "modexp output must be mod_len bytes"

  var empty: byte
  doAssert c_zkvm_modexp(
    (if b.len > 0: baseAddr(b) else: addr empty),
    csize_t(b.len),
    (if e.len > 0: baseAddr(e) else: addr empty),
    csize_t(e.len),
    baseAddr(m),
    csize_t(m.len),
    baseAddr(output),
  ) == ZKVM_EOK, "zkvm_modexp failed"

proc modExp*(b, e, m: openArray[byte]): seq[byte] =
  if m.len == 0:
    return
  result = newSeq[byte](m.len)
  modExpInto(b, e, m, result)

proc verifyRaw*(
    sig: openArray[byte], hash: openArray[byte], pubkey: openArray[byte]
): bool =
  ## secp256r1 (P-256) signature verification, EIP-7212.
  if sig.len != 64 or hash.len != 32 or pubkey.len != 64:
    return false

  var
    msgBuf: ZkvmBytes32
    sigBuf, keyBuf: ZkvmBytes64
    verified = false
  assign(msgBuf.data, hash)
  assign(sigBuf.data, sig)
  assign(keyBuf.data, pubkey)

  doAssert c_zkvm_secp256r1_verify(addr msgBuf, addr sigBuf, addr keyBuf, addr verified) ==
    ZKVM_EOK, "zkvm_secp256r1_verify failed"

  verified

proc bn254G1Add*(p1, p2: openArray[byte], output: var array[64, byte]): bool =
  ## EIP-196 point addition over `x ‖ y` big-endian coordinates.
  ##
  ## `false` also covers a rejected point, not just a failed accelerator: the
  ## vendor checks the coordinates are in the field and on the curve, and
  ## reports both the same way. `(0, 0)` is the point at infinity and accepted.
  if p1.len != 64 or p2.len != 64:
    return false

  var a, b, res: ZkvmBytes64
  assign(a.data, p1)
  assign(b.data, p2)

  if c_zkvm_bn254_g1_add(addr a, addr b, addr res) != ZKVM_EOK:
    return false

  output = res.data
  true

proc bn254G1Mul*(point, scalar: openArray[byte], output: var array[64, byte]): bool =
  ## EIP-196 scalar multiplication.
  ##
  ## `false` covers a rejected point as above.
  if point.len != 64 or scalar.len != 32:
    return false

  var
    p, res: ZkvmBytes64
    k: ZkvmBytes32
  assign(p.data, point)
  assign(k.data, scalar)

  if c_zkvm_bn254_g1_mul(addr p, addr k, addr res) != ZKVM_EOK:
    return false

  output = res.data
  true

proc bn254Pairing*(pairs: openArray[byte], verified: var bool): bool =
  ## EIP-197 pairing check over `pairs`. `verified` says whether the
  ## product of the pairings is one.
  ##
  ## `false` covers a rejected point as above.
  if pairs.len == 0 or pairs.len mod 192 != 0:
    return false

  let count = pairs.len div 192
  var buf = newSeq[ZkvmBn254PairingPair](count)
  copyMem(addr buf[0], baseAddr(pairs), pairs.len)

  if c_zkvm_bn254_pairing(addr buf[0], csize_t(count), addr verified) != ZKVM_EOK:
    return false

  true

proc blake2fCompress*(
    rounds: uint32,
    state: var openArray[byte],
    msg: openArray[byte],
    offset: openArray[byte],
    final: bool,
): bool =
  ## BLAKE2f compression, EIP-152.
  if state.len != 64 or msg.len != 128 or offset.len != 16:
    return false

  var
    h: ZkvmBytes64
    m: ZkvmBytes128
    t: ZkvmBytes16
  assign(h.data, state)
  assign(m.data, msg)
  assign(t.data, offset)

  doAssert c_zkvm_blake2f(rounds, addr h, addr m, addr t, uint8(final)) == ZKVM_EOK,
    "zkvm_blake2f failed"

  assign(state, h.data)
  true

proc verifyKzgProofRaw*(
    commitment: openArray[byte],
    z: openArray[byte],
    y: openArray[byte],
    proof: openArray[byte],
): bool =
  ## KZG point evaluation, EIP-4844.
  if commitment.len != 48 or z.len != 32 or y.len != 32 or proof.len != 48:
    return false

  var
    commitmentBuf, proofBuf: ZkvmBytes48
    zBuf, yBuf: ZkvmBytes32
    verified = false
  assign(commitmentBuf.data, commitment)
  assign(zBuf.data, z)
  assign(yBuf.data, y)
  assign(proofBuf.data, proof)

  doAssert c_zkvm_kzg_point_eval(
    addr commitmentBuf, addr zBuf, addr yBuf, addr proofBuf, addr verified
  ) == ZKVM_EOK, "zkvm_kzg_point_eval failed"

  verified
