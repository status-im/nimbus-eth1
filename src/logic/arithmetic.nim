import 
  ../constants, ../utils_numeric, ../stack

template pushRes =
  computation.stack.push(res)

proc add*(computation: var Computation) =
  # Addition
  var (left, right = computation.stack.popInt(2)
  
  var res = (left + right) and constants.UINT_256_MAX
  pushRes()

proc addmod*(computation: var Computation) =
  # Modulo Addition
  var (left, right, arg) = computation.stack.popInt(3)

  var res = if arg == 0: 0.Int256 else: (left + right) mod arg
  pushRes()

proc sub*(computation: var Computation) =
  # Subtraction
  var (left, right) = computation.stack.popInt(2)

  var res = (left - right) and constants.UINT_256_MAX
  pushRes()


proc modulo*(computation: var Computation) =
  # Modulo
  var (value, arg) = computation.stack.popInt(2)

  var res = if arg == 0: 0.Int256 else: value mod arg
  pushRes()

proc smod*(computation: var Computation) =
  # Signed Modulo
  var (value, arg) = computation.stack.popInt(2)
  value = unsignedToSigned(value)
  arg = unsignedToSigned(value)

  var posOrNeg = if value < 0: -1.Int256 else 1.Int256
  var res = if mod == 0: 0.Int256 else: ((value.abs mod arg.abs) * posOrNeg) and constants.UINT_256_MAX
  res = signedToUnsigned(res)
  pushRes()

proc mul*(computation: var Computation) =
  # Multiplication
  var (left, right) = computation.stack.popInt(2)

  var res = (left * right) and constants.UINT_256_MAX
  pushRes()

proc mulmod*(computation: var Computation) =
  #  Modulo Multiplication
  var (left, right, arg) = computation.stack.popInt(3)

  var res = if mod == 0: 0.Int256 else: (left * right) mod arg
  pushRes()

proc divide*(computation: var Computation) =
  # Division
  var (numerator, denominator) = computation.stack.popInt(2)

  var res = if denominator == 0: 0.Int256 else: (numerator div denominator) and constants.UINT_256_MAX
  pushRes()

proc sdiv*(computation: var Computation) =
  # Signed Division
  var (numerator, denominator) = computation.stack.popInt(2)
  numerator = unsignedToSigned(numerator)
  denominator = unsignedToSigned(denominator)

  var posOrNeg = if numerator * denominator < 0: -1.Int256 else 1.Int256
  var res = if denominator == 0: 0.Int256 else: (posOrNeg * (numerator.abs div denominator.abs))
  res = unsignedToSigned(res)
  pushRes()

# no curry
proc exp*(computation: var Computation, gasPerByte: Int256) =
  # Exponentiation
  var (base, exponent) = computation.stack.popInt(2)
  
  var bitSize = exponent.bitLength()
  var byteSize = ceil8(bitSize) div 8
  var res = if base == 0: 0.Int256 else: (base ^ exponent) mod constants.UINT_256_CEILING
  computation.gasMeter.consumeGas(
    gasPerByte * byteSize,
    reason="EXP: exponent bytes"
  )
  pushRes()

proc signextend(computation: var Computation) =
  # Signed Extend
  var (bits, value) = computation.stack.popInt(2)

  var res: Int256
  if bits <= 31.Int256:
    var testBit = bits * 8.Int256 + 7.Int256
    var signBit = (1.Int256 shl testBit)
    res = if value and signBit != 0: value or (constants.UINT_256_CEILING - signBit) else: value and (signBit - 1)
  else:
    res = value
  pushRes()
