import
  strformat, strutils, tables, macros,
  constants, ttmath, errors, logging, vm_state,
  vm / [gas_meter, stack, code_stream, memory, message, value, gas_costs], db / chain, computation, opcode, opcode_values, utils / [header, address],
  logic / [arithmetic, comparison, sha3, context, block_ops, stack_ops, duplication, swap, memory_ops, storage, flow, logging_ops, invalid, call, system_ops]

var opcodes = initOpcodes:
  # arithmetic
  Op.Add:           GAS_VERY_LOW        add
  Op.Mul:           GAS_LOW             mul
  Op.Sub:           GAS_VERY_LOW        sub
  Op.Div:           GAS_LOW             divide
  Op.SDiv:          GAS_LOW             sdiv
  Op.Mod:           GAS_LOW             modulo
  Op.SMod:          GAS_LOW             smod
  Op.AddMod:        GAS_MID             addmod
  Op.MulMod:        GAS_MID             mulmod
  Op.Exp:           expGasCost          arithmetic.exp
  Op.SignExtend:    GAS_LOW             signextend


  # comparison
  Op.Lt:            GAS_VERY_LOW        lt
  Op.Gt:            GAS_VERY_LOW        gt
  Op.SLt:           GAS_VERY_LOW        slt
  Op.SGt:           GAS_VERY_LOW        sgt
  Op.Eq:            GAS_VERY_LOW        eq
  Op.IsZero:        GAS_VERY_LOW        iszero
  Op.And:           GAS_VERY_LOW        andOp
  Op.Or:            GAS_VERY_LOW        orOp
  Op.Xor:           GAS_VERY_LOW        xorOp
  Op.Not:           GAS_VERY_LOW        notOp
  Op.Byte:          GAS_VERY_LOW        byteOp


  # sha3
  Op.SHA3:          GAS_SHA3            sha3op


  # context
  Op.Address:       GAS_BASE            context.address
  Op.Balance:       GAS_COST_BALANCE    balance
  Op.Origin:        GAS_BASE            origin
  Op.Caller:        GAS_BASE            caller
  Op.CallValue:     GAS_BASE            callValue
  Op.CallDataLoad:  GAS_VERY_LOW        callDataLoad
  Op.CallDataSize:  GAS_BASE            callDataSize
  Op.CallDataCopy:  GAS_BASE            callDataCopy
  Op.CodeSize:      GAS_BASE            codesize
  Op.CodeCopy:      GAS_BASE            codecopy
  Op.ExtCodeSize:   GAS_EXT_CODE_COST   extCodeSize
  Op.ExtCodeCopy:   GAS_EXT_CODE_COST   extCodeCopy


  # block
  Op.Blockhash:     GAS_BASE            block_ops.blockhash
  Op.Coinbase:      GAS_COINBASE        coinbase
  Op.Timestamp:     GAS_BASE            timestamp
  Op.Number:        GAS_BASE            number
  Op.Difficulty:    GAS_BASE            difficulty
  Op.GasLimit:      GAS_BASE            gaslimit
  

  # stack
  Op.Pop:           GAS_BASE            stack_ops.pop
  1..32 Op.PushXX:  GAS_VERY_LOW        pushXX # XX replaced by macro
  1..16 Op.DupXX:   GAS_VERY_LOW        dupXX
  1..16 Op.SwapXX:  GAS_VERY_LOW        swapXX


  # memory
  Op.MLoad:         GAS_VERY_LOW        mload
  Op.MStore:        GAS_VERY_LOW        mstore
  Op.MStore8:       GAS_VERY_LOW        mstore8
  Op.MSize:         GAS_BASE            msize

  # storage
  Op.SLoad:         GAS_SLOAD_COST      sload
  Op.SStore:        GAS_ZERO            sstore


  # flow
  Op.Jump:          GAS_MID             jump
  Op.JumpI:         GAS_MID             jumpi
  Op.PC:            GAS_HIGH            pc
  Op.Gas:           GAS_BASE            flow.gas
  Op.JumpDest:      GAS_JUMP_DEST       jumpdest
  Op.Stop:          GAS_ZERO            stop


  # logging
  0..4 Op.LogXX:    GAS_IN_HANDLER      logXX


  # invalid
  Op.Invalid:       GAS_ZERO            invalidOp


  # system
  Op.Return:        0.i256              returnOp
  Op.SelfDestruct:  GAS_SELF_DESTRUCT_COST selfdestruct


# call
opcodes[Op.Call] = Call(kind: Op.Call)
opcodes[Op.CallCode] = CallCode(kind: Op.CallCode)
opcodes[Op.DelegateCall] = DelegateCall(kind: Op.DelegateCall)


# system
opcodes[Op.Create] = Create(kind: Op.Create)

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
    blockHeader: Header(),
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
  opcodes: opcodes,
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

