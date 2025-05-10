# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  ../../evm/interpreter/codes

type
  InstrInfo* = object
    name*: string
    immediateSize*: int
    isTerminating*: bool
    stackHeightRequired*: int
    stackHeightChange*: int

template iinfo(a, b, c, d, e): auto =
  InstrInfo(
    name: a,
    immediateSize: b,
    isTerminating: c,
    stackHeightRequired: d,
    stackHeightChange: e
  )

const
  InstrTable* =
    block:
      var map: array[Op, InstrInfo]
      for x in Op:
        map[x] = iinfo("undefined", 0, true, 0, 0)

      map[Stop] = iinfo("STOP", 0, true, 0, 0)
      map[Add] = iinfo("ADD", 0, false, 2, -1)
      map[Mul] = iinfo("MUL", 0, false, 2, -1)
      map[Sub] = iinfo("SUB", 0, false, 2, -1)
      map[Div] = iinfo("DIV", 0, false, 2, -1)
      map[Sdiv] = iinfo("SDIV", 0, false, 2, -1)
      map[Mod] = iinfo("MOD", 0, false, 2, -1)
      map[Smod] = iinfo("SMOD", 0, false, 2, -1)
      map[Addmod] = iinfo("ADDMOD", 0, false, 3, -2)
      map[Mulmod] = iinfo("MULMOD", 0, false, 3, -2)
      map[Exp] = iinfo("EXP", 0, false, 2, -1)
      map[SignExtend] = iinfo("SIGNEXTEND", 0, false, 2, -1)

      map[Lt] = iinfo("LT", 0, false, 2, -1)
      map[Gt] = iinfo("GT", 0, false, 2, -1)
      map[Slt] = iinfo("SLT", 0, false, 2, -1)
      map[Sgt] = iinfo("SGT", 0, false, 2, -1)
      map[Eq] = iinfo("EQ", 0, false, 2, -1)
      map[IsZero] = iinfo("ISZERO", 0, false, 1, 0)
      map[And] = iinfo("AND", 0, false, 2, -1)
      map[Or] = iinfo("OR", 0, false, 2, -1)
      map[Xor] = iinfo("XOR", 0, false, 2, -1)
      map[Not] = iinfo("NOT", 0, false, 1, 0)
      map[Byte] = iinfo("BYTE", 0, false, 2, -1)
      map[Shl] = iinfo("SHL", 0, false, 2, -1)
      map[Shr] = iinfo("SHR", 0, false, 2, -1)
      map[Sar] = iinfo("SAR", 0, false, 2, -1)

      map[Keccak256] = iinfo("KECCAK256", 0, false, 2, -1)

      map[Address] = iinfo("ADDRESS", 0, false, 0, 1)
      map[Balance] = iinfo("BALANCE", 0, false, 1, 0)
      map[Origin] = iinfo("ORIGIN", 0, false, 0, 1)
      map[Caller] = iinfo("CALLER", 0, false, 0, 1)
      map[CallCalue] = iinfo("CALLVALUE", 0, false, 0, 1)
      map[CallDataLoad] = iinfo("CALLDATALOAD", 0, false, 1, 0)
      map[CallDataSize] = iinfo("CALLDATASIZE", 0, false, 0, 1)
      map[CallDataCopy] = iinfo("CALLDATACOPY", 0, false, 3, -3)
      map[CodeSize] = iinfo("CODESIZE", 0, false, 0, 1)
      map[CodeCopy] = iinfo("CODECOPY", 0, false, 3, -3)
      map[GasPrice] = iinfo("GASPRICE", 0, false, 0, 1)
      map[ExtCodeSize] = iinfo("EXTCODESIZE", 0, false, 1, 0)
      map[ExtCodeCopy] = iinfo("EXTCODECOPY", 0, false, 4, -4)
      map[ReturnDataSize] = iinfo("RETURNDATASIZE", 0, false, 0, 1)
      map[ReturnDataCopy] = iinfo("RETURNDATACOPY", 0, false, 3, -3)
      map[ExtCodeHash] = iinfo("EXTCODEHASH", 0, false, 1, 0)

      map[BlockHash] = iinfo("BLOCKHASH", 0, false, 1, 0)
      map[CoinBase] = iinfo("COINBASE", 0, false, 0, 1)
      map[Timestamp] = iinfo("TIMESTAMP", 0, false, 0, 1)
      map[Number] = iinfo("NUMBER", 0, false, 0, 1)
      map[Difficulty] = iinfo("PREVRANDAO", 0, false, 0, 1)
      map[GasLimit] = iinfo("GASLIMIT", 0, false, 0, 1)
      map[ChainIdOp] = iinfo("CHAINID", 0, false, 0, 1)
      map[SelfBalance] = iinfo("SELFBALANCE", 0, false, 0, 1)
      map[BaseFee] = iinfo("BASEFEE", 0, false, 0, 1)
      map[BlobHash] = iinfo("BLobHash", 0, false, 0, 1)
      map[BlobBaseFee] = iinfo("BlobBaseFee", 0, false, 0, 1)

      map[Pop] = iinfo("POP", 0, false, 1, -1)
      map[Mload] = iinfo("MLOAD", 0, false, 1, 0)
      map[Mstore] = iinfo("MSTORE", 0, false, 2, -2)
      map[Mstore8] = iinfo("MSTORE8", 0, false, 2, -2)
      map[Sload] = iinfo("SLOAD", 0, false, 1, 0)
      map[Sstore] = iinfo("SSTORE", 0, false, 2, -2)
      map[Jump] = iinfo("JUMP", 0, false, 1, -1)
      map[JumpI] = iinfo("JUMPI", 0, false, 2, -2)
      map[Pc] = iinfo("PC", 0, false, 0, 1)
      map[Msize] = iinfo("MSIZE", 0, false, 0, 1)
      map[Gas] = iinfo("GAS", 0, false, 0, 1)
      map[JumpDest] = iinfo("JUMPDEST", 0, false, 0, 0)
      map[Rjump] = iinfo("RJUMP", 2, false, 0, 0)
      map[RJUMPI] = iinfo("RJUMPI", 2, false, 1, -1)

      map[Push0] = iinfo("PUSH0", 0, false, 0, 1)

      map[Push1] = iinfo("PUSH1", 1, false, 0, 1)
      map[Push2] = iinfo("PUSH2", 2, false, 0, 1)
      map[Push3] = iinfo("PUSH3", 3, false, 0, 1)
      map[Push4] = iinfo("PUSH4", 4, false, 0, 1)
      map[Push5] = iinfo("PUSH5", 5, false, 0, 1)
      map[Push6] = iinfo("PUSH6", 6, false, 0, 1)
      map[Push7] = iinfo("PUSH7", 7, false, 0, 1)
      map[Push8] = iinfo("PUSH8", 8, false, 0, 1)
      map[Push9] = iinfo("PUSH9", 9, false, 0, 1)
      map[Push10] = iinfo("PUSH10", 10, false, 0, 1)
      map[Push11] = iinfo("PUSH11", 11, false, 0, 1)
      map[Push12] = iinfo("PUSH12", 12, false, 0, 1)
      map[Push13] = iinfo("PUSH13", 13, false, 0, 1)
      map[Push14] = iinfo("PUSH14", 14, false, 0, 1)
      map[Push15] = iinfo("PUSH15", 15, false, 0, 1)
      map[Push16] = iinfo("PUSH16", 16, false, 0, 1)
      map[Push17] = iinfo("PUSH17", 17, false, 0, 1)
      map[Push18] = iinfo("PUSH18", 18, false, 0, 1)
      map[Push19] = iinfo("PUSH19", 19, false, 0, 1)
      map[Push20] = iinfo("PUSH20", 20, false, 0, 1)
      map[Push21] = iinfo("PUSH21", 21, false, 0, 1)
      map[Push22] = iinfo("PUSH22", 22, false, 0, 1)
      map[Push23] = iinfo("PUSH23", 23, false, 0, 1)
      map[Push24] = iinfo("PUSH24", 24, false, 0, 1)
      map[Push25] = iinfo("PUSH25", 25, false, 0, 1)
      map[Push26] = iinfo("PUSH26", 26, false, 0, 1)
      map[Push27] = iinfo("PUSH27", 27, false, 0, 1)
      map[Push28] = iinfo("PUSH28", 28, false, 0, 1)
      map[Push29] = iinfo("PUSH29", 29, false, 0, 1)
      map[Push30] = iinfo("PUSH30", 30, false, 0, 1)
      map[Push31] = iinfo("PUSH31", 31, false, 0, 1)
      map[Push32] = iinfo("PUSH32", 32, false, 0, 1)

      map[Dup1] = iinfo("DUP1", 0, false, 1, 1)
      map[Dup2] = iinfo("DUP2", 0, false, 2, 1)
      map[Dup3] = iinfo("DUP3", 0, false, 3, 1)
      map[Dup4] = iinfo("DUP4", 0, false, 4, 1)
      map[Dup5] = iinfo("DUP5", 0, false, 5, 1)
      map[Dup6] = iinfo("DUP6", 0, false, 6, 1)
      map[Dup7] = iinfo("DUP7", 0, false, 7, 1)
      map[Dup8] = iinfo("DUP8", 0, false, 8, 1)
      map[Dup9] = iinfo("DUP9", 0, false, 9, 1)
      map[Dup10] = iinfo("DUP10", 0, false, 10, 1)
      map[Dup11] = iinfo("DUP11", 0, false, 11, 1)
      map[Dup12] = iinfo("DUP12", 0, false, 12, 1)
      map[Dup13] = iinfo("DUP13", 0, false, 13, 1)
      map[Dup14] = iinfo("DUP14", 0, false, 14, 1)
      map[Dup15] = iinfo("DUP15", 0, false, 15, 1)
      map[Dup16] = iinfo("DUP16", 0, false, 16, 1)

      map[Swap1] = iinfo("SWAP1", 0, false, 2, 0)
      map[Swap2] = iinfo("SWAP2", 0, false, 3, 0)
      map[Swap3] = iinfo("SWAP3", 0, false, 4, 0)
      map[Swap4] = iinfo("SWAP4", 0, false, 5, 0)
      map[Swap5] = iinfo("SWAP5", 0, false, 6, 0)
      map[Swap6] = iinfo("SWAP6", 0, false, 7, 0)
      map[Swap7] = iinfo("SWAP7", 0, false, 8, 0)
      map[Swap8] = iinfo("SWAP8", 0, false, 9, 0)
      map[Swap9] = iinfo("SWAP9", 0, false, 10, 0)
      map[Swap10] = iinfo("SWAP10", 0, false, 11, 0)
      map[Swap11] = iinfo("SWAP11", 0, false, 12, 0)
      map[Swap12] = iinfo("SWAP12", 0, false, 13, 0)
      map[Swap13] = iinfo("SWAP13", 0, false, 14, 0)
      map[Swap14] = iinfo("SWAP14", 0, false, 15, 0)
      map[Swap15] = iinfo("SWAP15", 0, false, 16, 0)
      map[Swap16] = iinfo("SWAP16", 0, false, 17, 0)

      map[Log0] = iinfo("LOG0", 0, false, 2, -2)
      map[Log1] = iinfo("LOG1", 0, false, 3, -3)
      map[Log2] = iinfo("LOG2", 0, false, 4, -4)
      map[Log3] = iinfo("LOG3", 0, false, 5, -5)
      map[Log4] = iinfo("LOG4", 0, false, 6, -6)

      map[CREATE] = iinfo("CREATE", 0, false, 3, -2)
      map[CALL] = iinfo("CALL", 0, false, 7, -6)
      map[CALLCODE] = iinfo("CALLCODE", 0, false, 7, -6)
      map[RETURN] = iinfo("RETURN", 0, true, 2, -2)
      map[DELEGATECALL] = iinfo("DELEGATECALL", 0, false, 6, -5)
      map[CREATE2] = iinfo("CREATE2", 0, false, 4, -3)
      map[STATICCALL] = iinfo("STATICCALL", 0, false, 6, -5)
      map[CALLF] = iinfo("CALLF", 2, false, 0, 0)
      map[RETF] = iinfo("RETF", 0, true, 0, 0)
      map[REVERT] = iinfo("REVERT", 0, true, 2, -2)
      map[INVALID] = iinfo("INVALID", 0, true, 0, 0)
      map[SELFDESTRUCT] = iinfo("SELFDESTRUCT", 0, true, 1, -1)

      map
