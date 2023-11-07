# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.


# EIP-3670: EOF - Code Validation
# EIP-5450: EOF - Stack Validation

import
  std/[tables, strutils],
  stew/[results, endians2],
  ../utils/eof,
  ../common/evmforks,
  ./interpreter/op_codes,
  ./analysis,
  ./stack_table

type
  OpDefined = array[Op, bool]

template EOFStackTable(): untyped =
  EVMForksStackTable[FkEOF]

func isTerminal(op: Op): bool =
  case op
  of RJUMP, RETF, STOP, RETURN, REVERT, INVALID:
    true
  else:
    false

proc parseUint16(code: openArray[byte], pos: int): int =
  fromBytesBE(uint16, toOpenArray(code, pos, pos+2-1)).int

proc parseInt16(code: openArray[byte], pos: int): int =
  let x = fromBytesBE(uint16, toOpenArray(code, pos, pos+2-1))
  cast[int16](x).int

# checkDest parses a relative offset at code[0:2] and checks if it is a valid jump destination.
proc checkDest(code: openArray[byte], analysis: Bitvec,
               imm, src, length: int): Result[void, EOFV1Error] =
  if code.len < imm+2:
    return err(eofErr(ErrUnexpectedEOF, code.len))

  let offset = parseInt16(code, imm)
  let dest = src + offset
  if dest < 0 or dest >= length:
    return err(eofErr(ErrInvalidJumpDest,
      imm,
      "relative offset out-of-bounds: offset $1, dest $2" %
      [$offset, $dest]))

  if not analysis.codeSegment(dest):
    return err(eofErr(ErrInvalidJumpDest,
      imm,
      "relative offset into immediate value: offset $1, dest $2" %
      [$offset, $dest]))

  ok()

proc stackOverflow(pos: int, len: int, limit: int, msg = ""): EOFV1Error =
  if msg.len == 0:
    eofErr(ErrStackOverflow, pos, "len: $1, limit: $2" % [$len, $limit])
  else:
    eofErr(ErrStackOverflow, pos, "len: $1, limit: $2, $3" % [$len, $limit, msg])

proc stackUnderflow(pos: int, len: int, req: int, msg = ""): EOFV1Error =
  if msg.len == 0:
    eofErr(ErrStackUnderflow, pos, "($1 <=> $2)" % [$len, $req])
  else:
    eofErr(ErrStackUnderflow, pos, "($1 <=> $2), $3" % [$len, $req, msg])

# validateControlFlow iterates through all possible branches the provided code
# value and determines if it is valid per EOF v1.
proc validateControlFlow(code: openArray[byte],
                         section: int,
                         metadata: openArray[FunctionMetadata],
                         st: StackTable): Result[int, EOFV1Error] =
  var
    heights        = initTable[int, int]()
    worklist       = @[(0, metadata[section].input.int)]
    maxStackHeight = metadata[section].input.int

  while worklist.len > 0:
    var (pos, height) = worklist.pop()

    block outer:
      while pos < code.len:
        let op = Op(code[pos])

        # Check if pos has already be visited; if so, the stack heights should be the same.
        heights.withValue(pos, val) do:
          let want = val[]
          if height != want:
            return err(eofErr(ErrConflictingStack, pos,
              "have $1, want $2" % [$height, $want]))
          # Already visited this path and stack height
          # matches.
          break
        heights[pos] = height

        # Validate height for current op and update as needed.
        if st[op].min > height:
          return err(stackUnderflow(pos, height, st[op].min))

        if st[op].max < height:
          return err(stackOverflow(pos, height, st[op].max))

        height += StackLimit - st[op].max

        case op
        of CALLF:
          let arg = parseUint16(code, pos+1)
          if metadata[arg].input.int > height:
            return err(stackUnderflow(pos, height, metadata[arg].input.int,
              "CALLF underflow to section " & $arg))

          if metadata[arg].output.int+height > StackLimit:
            return err(stackOverflow(pos, metadata[arg].output.int+height, StackLimit,
              "CALLF overflow to section " & $arg))

          height -= metadata[arg].input.int
          height += metadata[arg].output.int
          pos += 3
        of RETF:
          if int(metadata[section].output) != height:
            return err(eofErr(ErrInvalidOutputs, pos,
              "have $1, want $1" %
              [$metadata[section].output, $height]))
          break outer
        of RJUMP:
          let arg = parseInt16(code, pos+1)
          pos += 3 + arg
        of RJUMPI:
          let arg = parseInt16(code, pos+1)
          worklist.add((pos + 3 + arg, height))
          pos += 3
        of RJUMPV:
          let count = int(code[pos+1])
          for i in 0 ..< count:
            let arg = parseInt16(code, pos+2+2*i)
            worklist.add((pos + 2 + 2*count + arg, height))
          pos += 2 + 2*count
        else:
          if op >= PUSH1 and op <= PUSH32:
            pos += 1 + op.int-PUSH0.int
          elif isTerminal(op):
            break outer
          else:
            # Simple op, no operand.
            pos += 1

        maxStackHeight = max(maxStackHeight, height)

  if maxStackHeight != metadata[section].maxStackHeight.int:
    return err(eofErr(ErrInvalidMaxStackHeight, 0,
      "at code section $1, have $2, want $3" %
        [$section, $metadata[section].maxStackHeight, $maxStackHeight]))

  ok(heights.len)

# validateCode validates the code parameter against the EOF v1 validity requirements.
proc validateCode(code: openArray[byte],
                  section: int,
                  metadata: openArray[FunctionMetadata],
                  st: StackTable): Result[void, EOFV1Error] =
  var
    i = 0
    # Tracks the number of actual instructions in the code (e.g.
    # non-immediate values). This is used at the end to determine
    # if each instruction is reachable.
    count    = 0
    analysis = eofCodeBitmap(code)
    op: Op

  # This loop visits every single instruction and verifies:
  # * if the instruction is valid for the given jump table.
  # * if the instruction has an immediate value, it is not truncated.
  # * if performing a relative jump, all jump destinations are valid.
  # * if changing code sections, the new code section index is valid and
  #   will not cause a stack overflow.
  while i < code.len:
    inc count
    op = Op(code[i])
    if not st[op].enabled:
      return err(eofErr(ErrUndefinedInstruction,
        i, "opcode=" & $op))

    case op
    of PUSH1..PUSH32:
      let size = op.int - PUSH0.int
      if code.len <= i+size:
        return err(eofErr(ErrTruncatedImmediate,
          i, "op=" & $op))
      i += size
    of RJUMP, RJUMPI:
      if code.len <= i+2:
        return err(eofErr(ErrTruncatedImmediate,
          i, "op=" & $op))
      let res = checkDest(code, analysis, i+1, i+3, code.len)
      if res.isErr:
        return res
      i += 2
    of RJUMPV:
      if code.len <= i+1:
        return err(eofErr(ErrTruncatedImmediate,
          i, "jump table size missing"))
      let count = int(code[i+1])
      if count == 0:
        return err(eofErr(ErrInvalidBranchCount,
          i, "must not be 0"))
      if code.len <= i+count:
        return err(eofErr(ErrTruncatedImmediate,
          i, "jump table truncated"))
      for j in 0 ..< count:
        let res = checkDest(code, analysis, i+2+j*2, i+2*count+2, code.len)
        if res.isErr:
          return res
      i += 1 + 2*count
    of CALLF:
      if i+2 >= code.len:
        return err(eofErr(ErrTruncatedImmediate,
          i, "op=" & $op))
      let arg = parseUint16(code, i+1)
      if arg >= metadata.len:
        return err(eofErr(ErrInvalidSectionArgument,
          i, "arg $1, last section $2" % [$arg, $metadata.len]))
      i += 2
    else:
      discard
    inc i

  # Code sections may not "fall through" and require proper termination.
  # Therefore, the last instruction must be considered terminal.
  if not isTerminal(op):
    return err(eofErr(ErrInvalidCodeTermination,
      i, "ends with op " & $op))

  let res = validateControlFlow(code, section, metadata, st)
  if res.isErr:
    return err(res.error)

  let paths = res.get()
  if paths != count:
    # TODO: return actual unreachable position
    return err(eofErr(ErrUnreachableCode, 0, ""))

  ok()

proc validateCode*(code: openArray[byte], section: int,
                  metadata: openArray[FunctionMetadata]): Result[void, EOFV1Error] =
  validateCode(code, section, metadata, EOFStackTable)

# ValidateCode validates each code section of the container against the EOF v1
# rule set.
proc validateCode*(c: Container): Result[void, EOFV1Error] =
  for i in 0 ..< c.code.len:
    let res = validateCode(c.code[i], i, c.types)
    if res.isErr:
      return res

  ok()
