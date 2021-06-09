# Nimbus - Services available to EVM code that is run for a transaction
#
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#{.push raises: [Defect].}

import
  sets, stint, chronicles, stew/ranges/ptr_arith,
  eth/common/eth_types,
  ".."/[vm_types, vm_computation],
  ./host_types

proc evmcResultRelease(res: var EvmcResult) {.cdecl, gcsafe.} =
  dealloc(res.output_data)

proc beforeExecCreateEvmcNested(host: TransactionHost,
                                m: EvmcMessage): Computation {.inline.} =
  # TODO: use evmc_message to avoid copy
  let childMsg = Message(
    kind: CallKind(m.kind),
    depth: m.depth,
    gas: m.gas,
    sender: m.sender.fromEvmc,
    value: m.value.fromEvmc,
    data: @(makeOpenArray(m.inputData, m.inputSize.int))
  )
  return newComputation(host.vmState, childMsg, cast[Hash256](m.create2_salt))

proc afterExecCreateEvmcNested(host: TransactionHost, child: Computation,
                               res: var EvmcResult) {.inline.} =
  if not child.shouldBurnGas:
    res.gas_left = child.gasMeter.gasRemaining

  if child.isSuccess:
    host.computation.merge(child)
    res.status_code = EVMC_SUCCESS
    res.create_address = child.msg.contractAddress.toEvmc
  else:
    res.status_code = if child.shouldBurnGas: EVMC_FAILURE else: EVMC_REVERT
    if child.output.len > 0:
      # TODO: can we move the ownership of seq to raw pointer?
      res.output_size = child.output.len.uint
      res.output_data = cast[ptr byte](alloc(child.output.len))
      copyMem(res.output_data, child.output[0].addr, child.output.len)
      res.release = evmcResultRelease

proc beforeExecCallEvmcNested(host: TransactionHost,
                              m: EvmcMessage): Computation {.inline.} =
  let childMsg = Message(
    kind: CallKind(m.kind),
    depth: m.depth,
    gas: m.gas,
    sender: m.sender.fromEvmc,
    codeAddress: m.destination.fromEvmc,
    contractAddress: if m.kind == EVMC_CALL:
                       m.destination.fromEvmc
                     else:
                       host.computation.msg.contractAddress,
    value: m.value.fromEvmc,
    data: @(makeOpenArray(m.inputData, m.inputSize.int)),
    flags: if m.isStatic: emvcStatic else: emvcNoFlags,
  )
  return newComputation(host.vmState, childMsg)

proc afterExecCallEvmcNested(host: TransactionHost, child: Computation,
                             res: var EvmcResult) {.inline.} =
  if not child.shouldBurnGas:
    res.gas_left = child.gasMeter.gasRemaining

  if child.isSuccess:
    host.computation.merge(child)
    res.status_code = EVMC_SUCCESS
  else:
    res.status_code = if child.shouldBurnGas: EVMC_FAILURE else: EVMC_REVERT

  if child.output.len > 0:
    # TODO: can we move the ownership of seq to raw pointer?
    res.output_size = child.output.len.uint
    res.output_data = cast[ptr byte](alloc(child.output.len))
    copyMem(res.output_data, child.output[0].addr, child.output.len)
    res.release = evmcResultRelease

# The next three functions are designed so `callEvmcNested` uses very small C
# stack usage for each level of nested EVM calls.
#
# To keep the C stack usage small when there are deeply nested EVM calls,
# `callEvmcNested` must use as little stack as possible, going from the EVM
# which calls it to the nested EVM which it calls.
#
# First, `callEvmcNested` itself is `template` so it is inlined to the caller
# at Nim level, not C level.  Only at Nim level is inlining guaranteed across
# `import`.  This saves a C stack frame, which matters because some C compilers
# reserve space for 1-3 copies of the large `EvmcResult` return value.
#
# Second, the complicated parts of preparation and return are done in
# out-of-line functions `beforeExecEvmcNested` and `afterExecEvmcNested`.  They
# are annotated with `{.noinline.}` to make sure they are out-of-line.  The
# annotation ensures they don't contribute to the stack frame of
# `callEvmcNested`, because otherwise the compiler can optimistically inline.
# (Even across modules when using `-flto`).
#
# The functions `beforeExecEvmcNested` and `afterExecEvmcNested` can use as
# much stack as they like.

proc beforeExecEvmcNested(host: TransactionHost, msg: EvmcMessage): Computation
    # This function must be declared with `{.noinline.}` to make sure it doesn't
    # contribute to the stack frame of `callEvmcNested` below.
    {.noinline.} =
  if msg.kind == EVMC_CREATE or msg.kind == EVMC_CREATE2:
    return beforeExecCreateEvmcNested(host, msg)
  else:
    return beforeExecCallEvmcNested(host, msg)

proc afterExecEvmcNested(host: TransactionHost, child: Computation,
                         kind: EvmcCallKind): EvmcResult
    # This function must be declared with `{.noinline.}` to make sure it doesn't
    # contribute to the stack frame of `callEvmcNested` below.
    {.noinline.} =
  if kind == EVMC_CREATE or kind == EVMC_CREATE2:
    afterExecCreateEvmcNested(host, child, result)
  else:
    afterExecCallEvmcNested(host, child, result)

template callEvmcNested*(host: TransactionHost, msg: EvmcMessage): EvmcResult =
  # This function must be declared `template` to ensure it is inlined at Nim
  # level to its caller across `import`.  C level `{.inline.}` won't do this.
  # Note that template parameters `host` and `msg` are multiple-evaluated.
  let child = beforeExecEvmcNested(host, msg)
  child.execCallOrCreate()
  afterExecEvmcNested(host, child, msg.kind)
