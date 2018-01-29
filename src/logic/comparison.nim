import
  ../constants, ../utils_numeric, ../computation, ../vm/stack,
  helpers, bigints

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

  var res = if value == 0: 1.i256 else: 0.i256
  pushRes()

proc notOp*(computation: var BaseComputation) =
  var value = computation.stack.popInt()

  var res = constants.UINT_256_MAX - value
  pushRes()

proc byteOp*(computation: var BaseComputation) =
  # Bitwise And
  var (position, value) = computation.stack.popInt(2)

  var res = if position >= 32.i256: 0.i256 else: (value div (256.i256.pow(31.i256 - position))) mod 256
  pushRes()

