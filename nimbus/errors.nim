# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

type
  EVMError* = object of CatchableError
    ## Base error class for all evm errors.

  BlockNotFound* = object of EVMError
    ## The block with the given number/hash does not exist.

  ParentNotFound* = object of EVMError
    ## The parent of a given block does not exist.

  CanonicalHeadNotFound* = object of EVMError
    ## The chain has no canonical head.

  ValidationError* = object of EVMError
    ## Error to signal something does not pass a validation check.

  VMError* = object of EVMError
    ## Class of errors which can be raised during VM execution.

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

  StackDepthError* = object of VMError
    ## Error signaling that the call stack has exceeded it's maximum allowed depth.

  ContractCreationCollision* = object of VMError
    ## Error signaling that there was an address collision during contract creation.

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

  StaticContextError* = object of VMError
    ## State changes not allowed in static call context
