# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, tables, macros,
  constants, stint, errors, logging, vm_state,
  vm / [gas_meter, stack, code_stream, memory, message, value], db / db_chain, computation, opcode, opcode_values, utils / [header, address],
  logic / [arithmetic, comparison, sha3, context, block_ops, stack_ops, duplication, swap, memory_ops, storage, flow, logging_ops, invalid, call, system_ops],
  ./vm_types

var OPCODE_TABLE* = initOpcodes:
  # arithmetic
  Op.Add:           GasVeryLow        add
  Op.Mul:           GasLow            mul
  Op.Sub:           GasVeryLow        sub
  Op.Div:           GasLow            divide
  Op.SDiv:          GasLow            sdiv
  Op.Mod:           GasLow            modulo
  Op.SMod:          GasLow            smod
  Op.AddMod:        GasMid            addmod
  Op.MulMod:        GasMid            mulmod
  Op.Exp:           GasInHandler      arithmetic.exp
  Op.SignExtend:    GasLow            signextend


  # comparison
  Op.Lt:            GasVeryLow        lt
  Op.Gt:            GasVeryLow        gt
  Op.SLt:           GasVeryLow        slt
  Op.SGt:           GasVeryLow        sgt
  Op.Eq:            GasVeryLow        eq
  Op.IsZero:        GasVeryLow        iszero
  Op.And:           GasVeryLow        andOp
  Op.Or:            GasVeryLow        orOp
  Op.Xor:           GasVeryLow        xorOp
  Op.Not:           GasVeryLow        notOp
  Op.Byte:          GasVeryLow        byteOp


  # sha3
  Op.SHA3:          GasSHA3           sha3op


  # context
  Op.Address:       GasBase           context.address
  Op.Balance:       GasBalance        balance
  Op.Origin:        GasBase           origin
  Op.Caller:        GasBase           caller
  Op.CallValue:     GasBase           callValue
  Op.CallDataLoad:  GasVeryLow        callDataLoad
  Op.CallDataSize:  GasBase           callDataSize
  Op.CallDataCopy:  GasBase           callDataCopy
  Op.CodeSize:      GasBase           codesize
  Op.CodeCopy:      GasBase           codecopy
  Op.ExtCodeSize:   GasExtCode        extCodeSize
  Op.ExtCodeCopy:   GasExtCode        extCodeCopy


  # block
  Op.Blockhash:     GasBase           block_ops.blockhash
  Op.Coinbase:      GasCoinbase       coinbase
  Op.Timestamp:     GasBase           timestamp
  Op.Number:        GasBase           number
  Op.Difficulty:    GasBase           difficulty
  Op.GasLimit:      GasBase           gaslimit


  # stack
  Op.Pop:           GasBase           stack_ops.pop
  1..32 Op.PushXX:  GasVeryLow        pushXX # XX replaced by macro
  1..16 Op.DupXX:   GasVeryLow        dupXX
  1..16 Op.SwapXX:  GasVeryLow        swapXX


  # memory
  Op.MLoad:         GasVeryLow        mload
  Op.MStore:        GasVeryLow        mstore
  Op.MStore8:       GasVeryLow        mstore8
  Op.MSize:         GasBase           msize

  # storage
  Op.SLoad:         GasSload          sload
  Op.SStore:        GasInHandler      sstore


  # flow
  Op.Jump:          GasMid            jump
  Op.JumpI:         GasMid            jumpi
  Op.PC:            GasHigh           pc
  Op.Gas:           GasBase           flow.gas
  Op.JumpDest:      GasJumpDest       jumpdest
  Op.Stop:          GasZero           stop


  # logging
  0..4 Op.LogXX:    GasInHandler      logXX


  # invalid
  Op.Invalid:       GasZero           invalidOp


  # system
  Op.Return:        GasZero           returnOp
  Op.SelfDestruct:  GasSelfDestruct   selfdestruct


# call
OPCODE_TABLE[Op.Call] = Call(kind: Op.Call)
OPCODE_TABLE[Op.CallCode] = CallCode(kind: Op.CallCode)
OPCODE_TABLE[Op.DelegateCall] = DelegateCall(kind: Op.DelegateCall)


# system
OPCODE_TABLE[Op.Create] = Create(kind: Op.Create)
