# Nimbus - Services available to EVM code that is run for a transaction
#
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/eth_types,
  stew/ptrops,
  stew/saturation_arith,
  stint,
  ../evm/[types, code_bytes, message],
  ../evm/interpreter_dispatch,
  ../utils/utils,
  "."/[host_types, host_trace]

import ../evm/computation except fromEvmc, toEvmc

proc evmcResultRelease(res: var EvmcResult) {.cdecl, gcsafe.} =
  dealloc(res.output_data)

proc beforeExecCreateEvmcNested(host: TransactionHost,
                                m: EvmcMessage): Computation =
  # TODO: use evmc_message to avoid copy
  let
    code = CodeBytesRef.init(makeOpenArray(m.input_data, m.input_size.int))
    childMsg = Message(
      kind: m.kind,
      depth: m.depth,
      gas: GasInt m.gas,
      sender: m.sender.fromEvmc,
      value: m.value.fromEvmc,
      contractAddress: generateContractAddress(
        host.vmState,
        m.kind,
        m.sender.fromEvmc,
        Bytes32(m.create2_salt.bytes),
        code)
    )
  newComputation(host.vmState, keepStack = false, childMsg, code)

proc afterExecCreateEvmcNested(host: TransactionHost, child: Computation,
                               res: var EvmcResult) {.inline.} =
  if not child.shouldBurnGas:
    res.gas_left = int64.saturate(child.gasMeter.gasRemaining)

  if child.isSuccess:
    res.gas_refund = child.gasMeter.gasRefunded
    res.status_code = EVMC_SUCCESS
    res.create_address = child.msg.contractAddress.toEvmc
  else:
    res.status_code = child.evmcStatus
    if child.output.len > 0:
      # TODO: can we move the ownership of seq to raw pointer?
      res.output_size = child.output.len.uint
      res.output_data = cast[ptr byte](alloc(child.output.len))
      copyMem(res.output_data, child.output[0].addr, child.output.len)
      res.release = evmcResultRelease

proc beforeExecCallEvmcNested(host: TransactionHost,
                              m: EvmcMessage): Computation {.inline.} =
  let childMsg = Message(
    kind: m.kind,
    depth: m.depth,
    gas: GasInt m.gas,
    sender: m.sender.fromEvmc,
    codeAddress: m.code_address.fromEvmc,
    contractAddress: if m.kind == EVMC_CALL:
                       m.recipient.fromEvmc
                     else:
                       host.computation.msg.contractAddress,
    value: m.value.fromEvmc,
    data: @(makeOpenArray(m.input_data, m.input_size.int)),
    flags: m.flags,
  )
  let code = getCallCode(host.vmState, childMsg.codeAddress)
  newComputation(host.vmState, keepStack = false, childMsg, code)

proc afterExecCallEvmcNested(host: TransactionHost, child: Computation,
                             res: var EvmcResult) {.inline.} =
  if not child.shouldBurnGas:
    res.gas_left = int64.saturate(child.gasMeter.gasRemaining)

  if child.isSuccess:
    res.gas_refund = child.gasMeter.gasRefunded
    res.status_code = EVMC_SUCCESS
  else:
    res.status_code = child.evmcStatus

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
  # `call` is special.  Most host functions do `flip256` in `evmc_host_glue`
  # and `show` in `host_services`, but `call` needs to minimise C stack used
  # by nested EVM calls.  Just `flip256` in glue's `call` adds a lot of
  # stack: +65% in tests, enough to blow our 750kiB test stack target and
  # crash.  Easily avoided by doing `flip256` and `show` out-of-line here.
  var msg = msg # Make a local copy that's ok to modify.
  msg.value = flip256(msg.value)
  host.showCallEntry(msg)
  let c = if msg.kind == EVMC_CREATE or msg.kind == EVMC_CREATE2:
            beforeExecCreateEvmcNested(host, msg)
          else:
            beforeExecCallEvmcNested(host, msg)
  when defined(evmc_enabled):
    c.host.init(cast[ptr nimbus_host_interface](host.hostInterface),
                cast[typeof(c.host.context)](host))
  host.saveComputation.add(host.computation)
  host.computation = c
  return c

proc afterExecEvmcNested(host: TransactionHost, child: Computation,
                         kind: EvmcCallKind): EvmcResult
    # This function must be declared with `{.noinline.}` to make sure it doesn't
    # contribute to the stack frame of `callEvmcNested` below.
    {.noinline.} =
  host.computation = host.saveComputation[^1]
  host.saveComputation[^1] = nil
  host.saveComputation.setLen(host.saveComputation.len - 1)
  if kind == EVMC_CREATE or kind == EVMC_CREATE2:
    afterExecCreateEvmcNested(host, child, result)
  else:
    afterExecCallEvmcNested(host, child, result)
  host.showCallReturn(result, kind.isCreate)

template callEvmcNested*(host: TransactionHost, msg: EvmcMessage): EvmcResult =
  # `call` is special.  The C stack usage must be kept small for deeply nested
  # EVM calls.  To ensure small stack, this function must use `template` to
  # inline at Nim level (same for `host.call(msg)`).  `{.inline.}` is not good
  # enough.  Due to object return it ends up using a lot more stack.  (Note
  # that template parameters `host` and `msg` are multiple-evaluated here;
  # simple expressions must be used when calling.)
  let child = beforeExecEvmcNested(host, msg)
  child.execCallOrCreate()
  afterExecEvmcNested(host, child, msg.kind)
