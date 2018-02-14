type
  EVMError* = object of Exception
    ## Base error class for all evm errors.

  VMNotFound* = object of EVMError
    ## No VM available for the provided block number.
  
  BlockNotFound* = object of EVMError
    ## The block with the given number/hash does not exist.

  ParentNotFound* = object of EVMError
    ## The parent of a given block does not exist.

  CanonicalHeadNotFound* = object of EVMError
    ## The chain has no canonical head.

  ValidationError* = object of EVMError
    ## Error to signal something does not pass a validation check.

  Halt* = object of EVMError
    ## Raised by opcode function to halt vm execution.

  VMError* = object of EVMError
    ## Class of errors which can be raised during VM execution.
    erasesReturnData*: bool
    burnsGas*: bool

  OutOfGas* = object of VMError
    ## Error signaling that VM execution has run out of gas.

  InsufficientStack* = object of VMError
    ## Error signaling that the stack is empty.

  FullStack* = object of VMError
    ## Error signaling that the stack is full.

  InvalidJumpDestination* = object of VMError
    ## Error signaling that the jump destination for a JUMPDEST operation is invalid.

  InvalidInstruction* = object of VMError
    ## Error signaling that an opcode is invalid.

  InsufficientFunds* = object of VMError
    ## Error signaling that an account has insufficient funds to transfer the
    ## requested value.

  StackDepthLimit* = object of VMError
    ## Error signaling that the call stack has exceeded it's maximum allowed depth.

  ContractCreationCollision* = object of VMError
    ## Error signaling that there was an address collision during contract creation.

  Revert* = object of VMError
    ##     Error used by the REVERT opcode

  WriteProtection* = object of VMError
    ## Error raised if an attempt to modify the state database is made while
    ## operating inside of a STATICCALL context.

  OutOfBoundsRead* = object of VMError
    ## Error raised to indicate an attempt was made to read data beyond the
    ## boundaries of the buffer (such as with RETURNDATACOPY)

  TypeError* = object of VMError
    ## Error when invalid values are found

  NotImplementedError* = object of VMError
    ## Not implemented error

#proc makeVMError*: ref VMError =
#  var e: ref VMError
#  new(e)
#  e.burnsGas = true
#  e.erasesReturnData = true
#var a: ref VMError
#new(a)

# proc makeRevert*(): Revert =
#   result.burnsGas = false
#   result.erasesReturnData = false

#var e = VMError()
#raise makeVMError()
#var e: ref VMError
#new(e)
#echo e[]
#proc x* =   
#  raise newException(VMError, "")
#var e = makeVMError()
#echo e[]


#x()