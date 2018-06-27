# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, eth_common/eth_types,
  ../../vm_types, ./opcode_values,
  opcodes_impl/[arithmetic, comparison, sha3, context, block_ops, stack_ops, duplication, swap, memory_ops, storage, flow, logging_ops, invalid, call, system_ops]

const
  OpLogic*: Table[Op, proc(computation: var BaseComputation){.nimcall.}] = {
    # 0s: Stop and Arithmetic Operations
    Stop:            stop,
    Add:             arithmetic.add,
    Mul:             mul,
    Sub:             sub,
    Div:             divide,
    Sdiv:            sdiv,
    Mod:             modulo,
    Smod:            smod,
    Addmod:          arithmetic.addmod,
    Mulmod:          arithmetic.mulmod,
    Exp:             arithmetic.exp,
    SignExtend:      signextend,

    # 10s: Comparison & Bitwise Logic Operations
    Lt:              lt,
    Gt:              gt,
    Slt:             slt,
    Sgt:             sgt,
    Eq:              eq,
    IsZero:          comparison.isZero,
    And:             andOp,
    Or:              orOp,
    Xor:             xorOp,
    Not:             notOp,
    Byte:            byteOp,

    # 20s: SHA3
    Sha3:            sha3op,

    # 30s: Environmental Information
    Address:         context.address,
    Balance:         balance,
    Origin:          context.origin,
    Caller:          caller,
    CallValue:       callValue,
    CallDataLoad:    callDataLoad,
    CallDataSize:    callDataSize,
    CallDataCopy:    callDataCopy,
    CodeSize:        codeSize,
    CodeCopy:        codeCopy,
    GasPrice:        gasPrice,     # TODO this wasn't used previously
    ExtCodeSize:     extCodeSize,
    ExtCodeCopy:     extCodeCopy,
    ReturnDataSize:  returnDataSize, # TODO this wasn't used previously
    ReturnDataCopy:  returnDataCopy,

    # 40s: Block Information
    Blockhash:       block_ops.blockhash,
    Coinbase:        block_ops.coinbase,
    Timestamp:       block_ops.timestamp,
    Number:          block_ops.number,
    Difficulty:      block_ops.difficulty,
    GasLimit:        block_ops.gaslimit,

    # 50s: Stack, Memory, Storage and Flow Operations
    Pop:            stack_ops.pop,
    Mload:          mload,
    Mstore:         mstore,
    Mstore8:        mstore8,
    Sload:          sload,
    Sstore:         sstore,
    Jump:           jump,
    JumpI:          jumpi,
    Pc:             pc,
    Msize:          msize,
    Gas:            flow.gas,
    JumpDest:       jumpDest,

    # 60s & 70s: Push Operations
    Push1:          push1,
    Push2:          push2,
    Push3:          push3,
    Push4:          push4,
    Push5:          push5,
    Push6:          push6,
    Push7:          push7,
    Push8:          push8,
    Push9:          push9,
    Push10:         push10,
    Push11:         push11,
    Push12:         push12,
    Push13:         push13,
    Push14:         push14,
    Push15:         push15,
    Push16:         push16,
    Push17:         push17,
    Push18:         push18,
    Push19:         push19,
    Push20:         push20,
    Push21:         push21,
    Push22:         push22,
    Push23:         push23,
    Push24:         push24,
    Push25:         push25,
    Push26:         push26,
    Push27:         push27,
    Push28:         push28,
    Push29:         push29,
    Push30:         push30,
    Push31:         push31,
    Push32:         push32,

    # 80s: Duplication Operations
    Dup1:           dup1,
    Dup2:           dup2,
    Dup3:           dup3,
    Dup4:           dup4,
    Dup5:           dup5,
    Dup6:           dup6,
    Dup7:           dup7,
    Dup8:           dup8,
    Dup9:           dup9,
    Dup10:          dup10,
    Dup11:          dup11,
    Dup12:          dup12,
    Dup13:          dup13,
    Dup14:          dup14,
    Dup15:          dup15,
    Dup16:          dup16,

    # 90s: Exchange Operations
    Swap1:          swap1,
    Swap2:          swap2,
    Swap3:          swap3,
    Swap4:          swap4,
    Swap5:          swap5,
    Swap6:          swap6,
    Swap7:          swap7,
    Swap8:          swap8,
    Swap9:          swap9,
    Swap10:         swap10,
    Swap11:         swap11,
    Swap12:         swap12,
    Swap13:         swap13,
    Swap14:         swap14,
    Swap15:         swap15,
    Swap16:         swap16,

    # a0s: Logging Operations
    Log0:           log0,
    Log1:           log1,
    Log2:           log2,
    Log3:           log3,
    Log4:           log4,

    # f0s: System operations
    # Create:         create,
    # Call:           call,
    # CallCode:       callCode,
    Return:         returnOp,
    # DelegateCall:   delegateCall,
    # StaticCall:     staticCall,
    Op.Revert:      revert,
    Invalid:        invalidOp,
    SelfDestruct:   selfDestruct
  }.toTable
