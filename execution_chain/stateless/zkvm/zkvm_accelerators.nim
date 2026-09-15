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
## TODO: bind the rest. Only the three replacing a BoringSSL backend are here;
## the header also declares keccak256, secp256k1, bn254, bls12-381, kzg and
## blake2f, all of which the guest currently computes in RISC-V instead.
##
## Every function returns `ZKVM_EOK` or `ZKVM_EFAIL`. A failure means the
## accelerator could not run at all, which is a broken guest rather than bad
## input: rejecting a malformed signature is `verified = false` with `ZKVM_EOK`.
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
  ZkvmBytes32 {.importc: "zkvm_bytes_32", header: zkvmAccelHdr.} = object
    data: array[32, byte]

  ZkvmBytes64 {.importc: "zkvm_bytes_64", header: zkvmAccelHdr.} = object
    data: array[64, byte]

# Only success needs a name: the header defines any non-zero as failure.
const ZKVM_EOK = ZkvmStatus(0)

# ------------------------------------------------------------------------------
# Bindings, one per header declaration
# ------------------------------------------------------------------------------

proc c_zkvm_sha256(
  data: ptr byte, len: csize_t, output: ptr ZkvmBytes32
): ZkvmStatus {.importc: "zkvm_sha256", header: zkvmAccelHdr.}

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
