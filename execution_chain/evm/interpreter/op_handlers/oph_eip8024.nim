# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  ../../evm_errors,
  ../../code_stream,
  ../../stack,
  ../../types,
  ../op_codes,
  ./oph_defs

func decodeSingle(x: int): int =
  if x <= 90:
    x + 17
  else:
    x - 20

func decodePair(x: int): (int, int) =
  var k: int
  if x <= 79:
    k = x
  else:
    k = x - 48

  let q = k div 16
  let r = k mod 16
  if q < r:
    (q + 1, r + 1)
  else:
    (r + 1, 29 - q)

func dupNOp(cpt: VmCpt): EvmResultVoid =
  ## 0xE6, The n‘th stack item is duplicated at the top of the stack
  let x = cpt.code.getImmediateByte()

  # This range is excluded to preserve compatibility with existing opcodes.
  if x > 90 and x < 128:
    return err(opErr(InvalidInstruction))

  let n = decodeSingle(x)

  # The n‘th stack item is duplicated at the top of the stack.
  cpt.stack.dup(n)

func swapNOp(cpt: VmCpt): EvmResultVoid =
  ## 0xE7, The n + 1‘th stack item is swapped with the top of the stack
  let x = cpt.code.getImmediateByte()

  # This range is excluded to preserve compatibility with existing opcodes.
  if x > 90 and x < 128:
    return err(opErr(InvalidInstruction))

  let n = decodeSingle(x)

  # The (n+1)‘th stack item is swapped with the top of the stack.
  cpt.stack.swapN(n)

func exchangeOp(cpt: VmCpt): EvmResultVoid =
  ## 0xE8, The n + 1‘th stack item is swapped with the m + 1‘th stack item
  let x = cpt.code.getImmediateByte()

  # This range is excluded both to preserve compatibility with existing opcodes
  # and to keep decode_pair’s 16-aligned arithmetic mapping valid (0–79, 128–255).
  if x > 79 and x < 128:
    return err(opErr(InvalidInstruction))

  let (n, m) = decodePair(x)
  cpt.stack.exchange(n, m)

const
  VmOpExecEIP8024*: seq[VmOpExec] = @[

    (opCode: DupN,      ## 0xE6, The n‘th stack item is duplicated at the top of the stack
     forks: VmOpAmsterdamAndLater,
     name: "dupn",
     info: "Duplicate n`th item to top of the stack",
     exec: VmOpFn dupNOp),


    (opCode: SwapN,     ## 0xE7, The n + 1‘th stack item is swapped with the top of the stack
     forks: VmOpAmsterdamAndLater,
     name: "swapn",
     info: "Swap n + 1`th item with top of the stack",
     exec: swapNOp),


    (opCode: Exchange,  ## 0xE8, The n + 1‘th stack item is swapped with the m + 1‘th stack item
     forks: VmOpAmsterdamAndLater,
     name: "exchange",
     info: "Swap n + 1`th with m + 1`th stack item",
     exec: exchangeOp)]
