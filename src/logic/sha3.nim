import
  ../constants, ../utils_numeric, .. / utils / [keccak, bytes], .. / vm / [stack, memory, gas_meter], ../computation, helpers, bigints

proc sha3op*(computation: var BaseComputation) =
  let (startPosition, size) = computation.stack.popInt(2)
  computation.extendMemory(startPosition, size)
  let sha3Bytes = computation.memory.read(startPosition, size)
  let wordCount = sha3Bytes.len.i256.ceil32 div 32
  let gasCost = constants.GAS_SHA3_WORD * wordCount
  computation.gasMeter.consumeGas(gasCost, reason="SHA3: word gas cost")
  var res = keccak("")
  pushRes()
