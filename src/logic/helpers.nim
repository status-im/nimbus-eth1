import macros

  
macro pushRes*: untyped =
  let resNode = ident("res")
  result = quote:
    computation.stack.push(`resNode`)

macro quasiBoolean*(name: untyped, op: untyped, signed: untyped = nil, nonzero: untyped = nil): untyped =
  var signedNode = newEmptyNode()
  var finishSignedNode = newEmptyNode()
  let resNode = ident("res")
  var leftNode = ident("left")
  var rightNode = ident("right")
  var actualLeftNode = leftNode
  var actualRightNode = rightNode
  if not signed.isNil:
    actualLeftNode = ident("leftSigned")
    actualRightNode = ident("rightSigned")
    signedNode = quote:
      let `actualLeftNode` = unsignedToSigned(`leftNode`)
      let `actualRightNode` = unsignedToSigned(`rightNode`)
  var test = if nonzero.isNil:
      quote:
        `op`(`actualLeftNode`, `actualRightNode`)
    else:
      quote:
        `op`(`actualLeftNode`, `actualRightNode`) != 0
  result = quote:
    proc `name`*(computation: var BaseComputation) =
      var (`leftNode`, `rightNode`) = computation.stack.popInt(2)
      `signedNode`
      
      var `resNode` = if `test`: 1.u256 else: 0.u256
      computation.stack.push(`resNode`)
