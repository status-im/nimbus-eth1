# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/tables,
  results,
  stint,
  stew/[assign2, byteutils],
  eth/common/hashes,
  web3/encoding

export
  results

type
  EvmErrorCode* {.pure.} = enum
    EvmBug
    OutOfGas
    MemoryFull
    StackFull
    StackInsufficient
    PrcInvalidSig
    PrcInvalidPoint
    PrcInvalidParam
    PrcValidationError
    GasIntOverflow
    InvalidInstruction
    StaticContext
    InvalidJumpDest
    OutOfBounds
    InvalidInitCode
    EvmInvalidParam

  EvmErrorObj* = object
    code*: EvmErrorCode

  EvmResultVoid* = Result[void, EvmErrorObj]
  EvmResult*[T] = Result[T, EvmErrorObj]

template gasErr*(errCode): auto =
  EvmErrorObj(
    code: EvmErrorCode.errCode,
  )

template memErr*(errCode): auto =
  EvmErrorObj(
    code: EvmErrorCode.errCode,
  )

template stackErr*(errCode): auto =
  EvmErrorObj(
    code: EvmErrorCode.errCode,
  )

template prcErr*(errCode): auto =
  EvmErrorObj(
    code: EvmErrorCode.errCode,
  )

template opErr*(errCode): auto =
  EvmErrorObj(
    code: EvmErrorCode.errCode,
  )

template evmErr*(errCode): auto =
  EvmErrorObj(
    code: EvmErrorCode.errCode,
  )


# revertSelector is a special function selector for revert reason unpacking
const revertSelector = keccak256(toBytes("Error(string)")).data[0..3]

# panicSelector is a special function selector for panic reason unpacking
const panicSelector = keccak256(toBytes("Panic(uint256)")).data[0..3]

# panicReasons map is for readable panic codes
# see this linkage for the details
# https://docs.soliditylang.org/en/v0.8.21/control-structures.html#panic-via-assert-and-error-via-require
# the reason string list is copied from Geth
# https://github.com/ethers-io/ethers.js/blob/fa3a883ff7c88611ce766f58bdd4b8ac90814470/src.ts/abi/interface.ts#L207-L218
const panicReasons = {
  0x00: "generic panic",
  0x01: "assert(false)",
  0x11: "arithmetic underflow or overflow",
  0x12: "division or modulo by zero",
  0x21: "enum overflow",
  0x22: "invalid encoded storage byte array accessed",
  0x31: "out-of-bounds array access; popping on an empty array",
  0x32: "out-of-bounds access of an array or bytesN",
  0x41: "out of memory",
  0x51: "uninitialized function",
}.toTable

# UnpackRevert resolves the abi-encoded revert reason. According to the solidity
# spec https://solidity.readthedocs.io/en/latest/control-structures.html#revert,
# the provided revert reason is abi-encoded as if it were a call to function
# `Error(string)` or `Panic(uint256)`.
proc unpackRevertReason*(data: openArray[byte], reason: var string) =
  if data.len() < 4:
    reason = ""
    return

  let selector = data[0..3]

  if selector == revertSelector:
    discard decode(data.toOpenArray(4, data.len() - 1), 0, 0, reason)
  elif selector == panicSelector:
    var reasonCode: UInt256
    discard decode(data.toOpenArray(4, data.len() - 1), 0, 0, reasonCode)
    assign(reason, panicReasons.getOrDefault(reasonCode.truncate(int)))
