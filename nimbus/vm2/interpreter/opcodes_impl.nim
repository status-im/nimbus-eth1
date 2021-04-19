# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./op_handlers/oph_defs,
  ./op_handlers_verify,
  ./op_handlers

# ##################################
# re-implemented OP handlers

template opHandler(callName: untyped; opCode: Op; fork = FkBerlin) =
  proc callName*(c: Computation) =
    var desc: Vm2Ctx
    desc.cpt = c
    vm2OpHandlers[fork][opCode].exec.run(desc)

opHandler            add, Op.Add
opHandler            mul, Op.Mul
opHandler            sub, Op.Sub
opHandler         divide, Op.Div
opHandler           sdiv, Op.Sdiv
opHandler         modulo, Op.Mod
opHandler           smod, Op.Smod
opHandler         addmod, Op.AddMod
opHandler         mulmod, Op.MulMod
opHandler            exp, Op.Exp
opHandler     signExtend, Op.SignExtend
opHandler             lt, Op.Lt
opHandler             gt, Op.Gt
opHandler            slt, Op.Slt
opHandler            sgt, Op.Sgt
opHandler             eq, Op.Eq
opHandler         isZero, Op.IsZero
opHandler          andOp, Op.And
opHandler           orOp, Op.Or
opHandler          xorOp, Op.Xor
opHandler          notOp, Op.Not
opHandler         byteOp, Op.Byte
opHandler          shlOp, Op.Shl
opHandler          shrOp, Op.Shr
opHandler          sarOp, Op.Sar
opHandler           sha3, Op.Sha3
opHandler        address, Op.Address

opHandler            balance, Op.Balance, FkFrontier
opHandler     balanceEIP2929, Op.Balance

opHandler         origin, Op.Origin
opHandler         caller, Op.Caller
opHandler      callValue, Op.CallValue
opHandler   callDataLoad, Op.CallDataLoad
opHandler   callDataSize, Op.CallDataSize
opHandler   callDataCopy, Op.CallDataCopy
opHandler       codeSize, Op.CodeSize
opHandler       codeCopy, Op.CodeCopy
opHandler       gasprice, Op.GasPrice

opHandler        extCodeSize, Op.ExtCodeSize, FkFrontier
opHandler extCodeSizeEIP2929, Op.ExtCodeSize

opHandler        extCodeCopy, Op.ExtCodeCopy, FkFrontier
opHandler extCodeCopyEIP2929, Op.ExtCodeCopy

opHandler returnDataSize, Op.ReturnDataSize
opHandler returnDataCopy, Op.ReturnDataCopy

opHandler        extCodeHash, Op.ExtCodeHash, FkConstantinople
opHandler extCodeHashEIP2929, Op.ExtCodeHash

opHandler      blockhash, Op.Blockhash
opHandler       coinbase, Op.Coinbase
opHandler      timestamp, Op.Timestamp
opHandler    blocknumber, Op.Number
opHandler     difficulty, Op.Difficulty
opHandler       gasLimit, Op.GasLimit
opHandler        chainId, Op.ChainId
opHandler    selfBalance, Op.SelfBalance
opHandler            pop, Op.Pop
opHandler          mload, Op.Mload
opHandler         mstore, Op.Mstore
opHandler        mstore8, Op.Mstore8

opHandler              sload, Op.Sload, FkFrontier
opHandler       sloadEIP2929, Op.Sload

opHandler             sstore, Op.Sstore, FkFrontier
opHandler      sstoreEIP1283, Op.Sstore, FkConstantinople
opHandler      sstoreEIP2200, Op.Sstore, FkIstanbul
opHandler      sstoreEIP2929, Op.Sstore

opHandler           jump, Op.Jump
opHandler          jumpI, Op.JumpI
opHandler             pc, Op.Pc
opHandler          msize, Op.Msize
opHandler            gas, Op.Gas
opHandler       jumpDest, Op.JumpDest
opHandler       beginSub, Op.BeginSub
opHandler      returnSub, Op.ReturnSub
opHandler        jumpSub, Op.JumpSub
opHandler          push1, Op.Push1
opHandler          push2, Op.Push2
opHandler          push3, Op.Push3
opHandler          push4, Op.Push4
opHandler          push5, Op.Push5
opHandler          push6, Op.Push6
opHandler          push7, Op.Push7
opHandler          push8, Op.Push8
opHandler          push9, Op.Push9
opHandler         push10, Op.Push10
opHandler         push11, Op.Push11
opHandler         push12, Op.Push12
opHandler         push13, Op.Push13
opHandler         push14, Op.Push14
opHandler         push15, Op.Push15
opHandler         push16, Op.Push16
opHandler         push17, Op.Push17
opHandler         push18, Op.Push18
opHandler         push19, Op.Push19
opHandler         push20, Op.Push20
opHandler         push21, Op.Push21
opHandler         push22, Op.Push22
opHandler         push23, Op.Push23
opHandler         push24, Op.Push24
opHandler         push25, Op.Push25
opHandler         push26, Op.Push26
opHandler         push27, Op.Push27
opHandler         push28, Op.Push28
opHandler         push29, Op.Push29
opHandler         push30, Op.Push30
opHandler         push31, Op.Push31
opHandler         push32, Op.Push32
opHandler           dup1, Op.Dup1
opHandler           dup2, Op.Dup2
opHandler           dup3, Op.Dup3
opHandler           dup4, Op.Dup4
opHandler           dup5, Op.Dup5
opHandler           dup6, Op.Dup6
opHandler           dup7, Op.Dup7
opHandler           dup8, Op.Dup8
opHandler           dup9, Op.Dup9
opHandler          dup10, Op.Dup10
opHandler          dup11, Op.Dup11
opHandler          dup12, Op.Dup12
opHandler          dup13, Op.Dup13
opHandler          dup14, Op.Dup14
opHandler          dup15, Op.Dup15
opHandler          dup16, Op.Dup16
opHandler          swap1, Op.Swap1
opHandler          swap2, Op.Swap2
opHandler          swap3, Op.Swap3
opHandler          swap4, Op.Swap4
opHandler          swap5, Op.Swap5
opHandler          swap6, Op.Swap6
opHandler          swap7, Op.Swap7
opHandler          swap8, Op.Swap8
opHandler          swap9, Op.Swap9
opHandler         swap10, Op.Swap10
opHandler         swap11, Op.Swap11
opHandler         swap12, Op.Swap12
opHandler         swap13, Op.Swap13
opHandler         swap14, Op.Swap14
opHandler         swap15, Op.Swap15
opHandler         swap16, Op.Swap16
opHandler           log0, Op.Log0
opHandler           log1, Op.Log1
opHandler           log2, Op.Log2
opHandler           log3, Op.Log3
opHandler           log4, Op.Log4
opHandler         create, Op.Create
opHandler           call, Op.Call
opHandler       callCode, Op.CallCode
opHandler        create2, Op.Create2
opHandler       returnOp, Op.Return
opHandler   delegateCall, Op.DelegateCall
opHandler     staticCall, Op.StaticCall
opHandler         revert, Op.Revert
opHandler      invalidOp, Op.Invalid

opHandler        selfDestruct, Op.SelfDestruct, FkFrontier
opHandler  selfDestructEIP150, Op.SelfDestruct, FkTangerine
opHandler  selfDestructEIP161, Op.SelfDestruct, FkSpurious
opHandler selfDestructEIP2929, Op.SelfDestruct
