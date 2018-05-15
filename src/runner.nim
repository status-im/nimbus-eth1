# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, tables, macros,
  constants, stint, errors, logging, vm_state, opcode_table,
  vm / [gas_meter, stack, code_stream, memory, message, value], db / chain, computation, opcode, opcode_values, utils / [header, address],
  logic / [arithmetic, comparison, sha3, context, block_ops, stack_ops, duplication, swap, memory_ops, storage, flow, logging_ops, invalid, call, system_ops]

var mem = newMemory(pow(1024.int256, 2))

var to = toCanonicalAddress("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
var sender = toCanonicalAddress("0xcd1722f3947def4cf144679da39c4c32bdc35681")

var code = ""
var data: seq[byte] = @[]

var msg = newMessage(
  25.int256,
  1.int256,
  to,
  sender,
  0.int256,
  data,
  code,
  MessageOptions(depth: 1))

var c = BaseComputation(
  vmState: BaseVMState(
    prevHeaders: @[],
    chaindb: BaseChainDB(),
    blockHeader: BlockHeader(),
    name: "zero"),
  msg: msg,
  memory: mem,
  stack: newStack(),
  gasMeter: newGasMeter(msg.gas),
  code: newCodeStream(code),
  children: @[],
  rawOutput: "",
  returnData: "",
  error: nil,
  logEntries: @[],
  shouldEraseReturnData: false,
  accountsToDelete: initTable[string, string](),
  opcodes: OPCODE_TABLE,
  precompiles: initTable[string, Opcode]())

# var c2 = c.applyComputation(c.vmState, c.msg)

macro runOpcodes*(computation: untyped, program: untyped): untyped =
  # runOpcodes(c):
  #   stack: @[Value..]
  #
  #   Op
  #   Op
  #
  # becomes
  #
  # c.stack.push(Value) ..
  #
  # c.getOpcodeFn(Op).run(c)
  # echo c.stack ..
  var stack = nnkStmtList.newTree()
  for child in program[0][1][0][1]:
    let push = quote:
      `computation`.stack.push(`child`)
    stack.add(push)

  var ops = nnkStmtList.newTree()
  for z, op in program:
    if z > 0:
      let run = quote:
        `computation`.getOpcodeFn(`op`).run(`computation`)
        echo `computation`.stack
      ops.add(run)

  result = nnkStmtList.newTree(stack, ops)

# useful for testing simple cases
runOpcodes(c):
  stack: @[2.vint, 2.vint, 2.vint, 2.vint, 2.vint, 2.vint, 4.vint]

  Op.Add
  Op.Mul
  Op.Div
  Op.Sub
  Op.Mul

