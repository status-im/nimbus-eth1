# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  helpers, ./impl_std_import

quasiBoolean(lt, `<`) # Lesser Comparison

quasiBoolean(gt, `>`) # Greater Comparison

quasiBoolean(slt, `<`, signed=true) # Signed Lesser Comparison

quasiBoolean(sgt, `>`, signed=true) # Signed Greater Comparison

quasiBoolean(eq, `==`) # Equality

quasiBoolean(andOp, `and`, nonzero=true) # Bitwise And

quasiBoolean(orOp, `or`, nonzero=true) # Bitwise Or

quasiBoolean(xorOp, `xor`, nonzero=true) # Bitwise XOr

# TODO use isZero from Stint
proc iszero*(computation: var BaseComputation) =
  var value = computation.stack.popInt()

  var res = if value == 0: 1.u256 else: 0.u256
  pushRes()

proc notOp*(computation: var BaseComputation) =
  var value = computation.stack.popInt()

  var res = UINT_256_MAX - value
  pushRes()

# TODO: seems like there is an implementation or a comment issue
#       this is not a bitwise "and" or the "byte" instruction
proc byteOp*(computation: var BaseComputation) =
  # Bitwise And

  var (position, value) = computation.stack.popInt(2)

  var res = if position >= 32.u256: 0.u256 else: (value div (256.u256.pow(31'u64 - position.toInt.uint64))) mod 256
  pushRes()
