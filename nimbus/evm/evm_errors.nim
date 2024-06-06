# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  results

export
  results

type
  EvmErrorCode* {.pure.} = enum
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
    EvmRlpError
    EvmBlockNotFound
    InvalidInitCode

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
