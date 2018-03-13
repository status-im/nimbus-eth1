import
  ../constants, ../utils_numeric, ../computation, ../vm/stack, ../types,
  helpers, ttmath

quasiBoolean(lt, `<`) # Lesser Comparison
    
quasiBoolean(gt, `>`) # Greater Comparison

quasiBoolean(slt, `<`, signed=true) # Signed Lesser Comparison

quasiBoolean(sgt, `>`, signed=true) # Signed Greater Comparison

quasiBoolean(eq, `==`) # Equality

quasiBoolean(andOp, `and`, nonzero=true) # Bitwise And

quasiBoolean(orOp, `or`, nonzero=true) # Bitwise Or

quasiBoolean(xorOp, `xor`, nonzero=true) # Bitwise XOr

proc iszero*(computation: var BaseComputation) =
  var value = computation.stack.popInt()

  var res = if value == 0: 1.u256 else: 0.u256
  pushRes()

proc notOp*(computation: var BaseComputation) =
  var value = computation.stack.popInt()

  var res = constants.UINT_256_MAX - value
  pushRes()

proc byteOp*(computation: var BaseComputation) =
  # Bitwise And
  var (position, value) = computation.stack.popInt(2)

  var res = if position >= 32.u256: 0.u256 else: (value div (256.u256.pow(31'u64 - position.getUInt))) mod 256
  pushRes()

