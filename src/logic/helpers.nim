import macros

  
template pushRes* =
  let resNode = ident("res")
  computation.stack.push(`resNode`)

macro quasiBoolean*(name: untyped, op: untyped, signed: untyped = nil, nonzero: untyped = nil): untyped =
  var signedNode = newEmptyNode()
  var finishSignedNode = newEmptyNode()
  let resNode = ident("res")
  let leftNode = ident("left")
  let rightNode = ident("right")
  if not signed.isNil:
    signedNode = quote:
      `leftNode` = unsignedToSigned(`leftNode`)
      `rightNode` = unsignedToSigned(`rightNode`)
    finishSignedNode = quote:
      `resNode` = signedToUnsigned(`resNode`)
  var test = if nonzero.isNil:
      quote:
        `op`(`leftNode`, `rightNode`)
    else:
      quote:
        `op`(`leftNode`, `rightNode`) != 0
  result = quote:
    proc `name`*(computation: var BaseComputation) =
      var (`leftNode`, `rightNode`) = computation.stack.popInt(2)
      `signedNode`
      
      var `resNode` = if `test`: 1.Int256 else: 0.Int256
      `finishSignedNode`
      computation.stack.push(`resNode`)
