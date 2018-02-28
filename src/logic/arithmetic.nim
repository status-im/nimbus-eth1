import 
  ../constants, ../utils_numeric, ../computation,
  .. / vm / [gas_meter, stack], ../opcode, ../opcode_values,
  helpers, ttmath, strutils

proc add*(computation: var BaseComputation) =
  # Addition
  var (left, right) = computation.stack.popInt(2)
  
  var res = (left + right) and UINT_256_MAX
  pushRes()

proc addmod*(computation: var BaseComputation) =
  # Modulo Addition
  var (left, right, arg) = computation.stack.popInt(3)

  var res = if arg == 0: 0.u256 else: (left + right) mod arg
  pushRes()

proc sub*(computation: var BaseComputation) =
  # Subtraction
  var (left, right) = computation.stack.popInt(2)

  var res = (left - right) and UINT_256_MAX
  pushRes()


proc modulo*(computation: var BaseComputation) =
  # Modulo
  var (value, arg) = computation.stack.popInt(2)

  var res = if arg == 0: 0.u256 else: value mod arg
  pushRes()

proc smod*(computation: var BaseComputation) =
  # Signed Modulo
  var (value, arg) = computation.stack.popInt(2)
  let signedValue = unsignedToSigned(value)
  let signedArg = unsignedToSigned(arg)

  var posOrNeg = if signedValue < 0: -1.i256 else: 1.i256
  var signedRes = if signedArg == 0: 0.i256 else: ((signedValue.abs mod signedArg.abs) * posOrNeg) and UINT_256_MAX_INT
  var res = signedToUnsigned(signedRes)
  pushRes()

proc mul*(computation: var BaseComputation) =
  # Multiplication
  var (left, right) = computation.stack.popInt(2)

  var res = (left * right) and UINT_256_MAX
  pushRes()

proc mulmod*(computation: var BaseComputation) =
  #  Modulo Multiplication
  var (left, right, arg) = computation.stack.popInt(3)

  var res = if arg == 0: 0.u256 else: (left * right) mod arg
  pushRes()

proc divide*(computation: var BaseComputation) =
  # Division
  var (numerator, denominator) = computation.stack.popInt(2)

  var res = if denominator == 0: 0.u256 else: (numerator div denominator) and UINT_256_MAX
  pushRes()

proc sdiv*(computation: var BaseComputation) =
  # Signed Division
  var (numerator, denominator) = computation.stack.popInt(2)
  let signedNumerator = unsignedToSigned(numerator)
  let signedDenominator = unsignedToSigned(denominator)

  var posOrNeg = if signedNumerator * signedDenominator < 0: -1.i256 else: 1.i256
  var signedRes = if signedDenominator == 0: 0.i256 else: (posOrNeg * (signedNumerator.abs div signedDenominator.abs))
  var res = signedToUnsigned(signedRes)
  pushRes()

# no curry
proc exp*(computation: var BaseComputation) =
  # Exponentiation
  let (base, exponent) = computation.stack.popInt(2)
  
  var gasCost = GAS_EXP_BYTE.u256
  #if exponent != 0:
  #  gasCost += GAS_EXP_BYTE * (1 + log256(exponent))
  gasCost += (ceil8(exponent.bitLength()) div 8).u256 * GAS_EXP_BYTE # TODO
  computation.gasMeter.consumeGas(gasCost, reason="EXP: exponent bytes")
  #echo "exp", base, " ", exponent, " ", res
  var res = if base == 0: 0.u256 else: base.pow(exponent)
  pushRes()

proc signextend*(computation: var BaseComputation) =
  # Signed Extend
  var (bits, value) = computation.stack.popInt(2)

  var res: UInt256
  if bits <= 31.u256:
    var testBit = bits.getUInt.int * 8 + 7
    var signBit = (1 shl testBit)
    res = if value != 0 and signBit != 0: value or (UINT_256_CEILING - signBit.u256) else: value and (signBit.u256 - 1.u256)
  else:
    res = value
  pushRes()
