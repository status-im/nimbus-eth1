# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

const
  # help with low memory when compiling selectVM() function
  lowmem {.intdefine.}: int = 0
  lowMemoryCompileTime {.used.} = lowmem > 0

import
  ../constants,
  ../db/accounts_cache,
  ./code_stream,
  ./computation,
  ./interpreter/op_dispatcher,
  ./message,
  ./precompiles,
  ./state,
  ./types,
  chronicles,
  eth/[common, keys],
  macros,
  options,
  sets,
  stew/byteutils,
  strformat

logScope:
  topics = "vm opcode"

const
  ripemdAddr = block:
    proc initAddress(x: int): EthAddress {.compileTime.} =
      result[19] = x.byte
    initAddress(3)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc selectVM(c: Computation, fork: Fork) {.gcsafe.} =
  ## Op code execution handler main loop.
  var desc: Vm2Ctx
  desc.cpt = c

  if c.tracingEnabled:
    c.prepareTracer()

  while true:
    c.instr = c.code.next()

    # Note Mamy's observation in opTableToCaseStmt() from original VM
    # regarding computed goto
    #
    # ackn:
    #   #{.computedGoto.}
    #   # computed goto causing stack overflow, it consumes a lot of space
    #   # we could use manual jump table instead
    #   # TODO lots of macro magic here to unravel, with chronicles...
    #   # `c`.logger.log($`c`.stack & "\n\n", fgGreen)
    when not lowMemoryCompileTime:
      when defined(release):
        #
        # FIXME: OS case list below needs to be adjusted
        #
        when defined(windows):
          when defined(cpu64):
            {.warning: "*** Win64/VM2 handler switch => computedGoto".}
            {.computedGoto, optimization: speed.}
          else:
            # computedGoto not compiling on github/ci (out of memory) -- jordan
            {.warning: "*** Win32/VM2 handler switch => optimisation disabled".}
            # {.computedGoto, optimization: speed.}

        elif defined(linux):
          when defined(cpu64):
            {.warning: "*** Linux64/VM2 handler switch => computedGoto".}
            {.computedGoto, optimization: speed.}
          else:
            {.warning: "*** Linux32/VM2 handler switch => computedGoto".}
            {.computedGoto, optimization: speed.}

        elif defined(macosx):
          when defined(cpu64):
            {.warning: "*** MacOs64/VM2 handler switch => computedGoto".}
            {.computedGoto, optimization: speed.}
          else:
            {.warning: "*** MacOs32/VM2 handler switch => computedGoto".}
            {.computedGoto, optimization: speed.}

        else:
          {.warning: "*** Unsupported OS => no handler switch optimisation".}

      genOptimisedDispatcher(fork, c.instr, desc)

    else:
      {.warning: "*** low memory compiler mode => program will be slow".}

      genLowMemDispatcher(fork, c.instr, desc)


proc beforeExecCall(c: Computation) =
  c.snapshot()
  if c.msg.kind == evmcCall:
    c.vmState.mutateStateDb:
      db.subBalance(c.msg.sender, c.msg.value)
      db.addBalance(c.msg.contractAddress, c.msg.value)

proc afterExecCall(c: Computation) =
  ## Collect all of the accounts that *may* need to be deleted based on EIP161
  ## https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  ## also see: https://github.com/ethereum/EIPs/issues/716

  if c.isError or c.fork >= FKByzantium:
    if c.msg.contractAddress == ripemdAddr:
      # Special case to account for geth+parity bug
      c.vmState.touchedAccounts.incl c.msg.contractAddress

  if c.isSuccess:
    c.commit()
    c.touchedAccounts.incl c.msg.contractAddress
  else:
    c.rollback()


proc beforeExecCreate(c: Computation): bool =
  c.vmState.mutateStateDB:
    db.incNonce(c.msg.sender)

    # We add this to the access list _before_ taking a snapshot.
    # Even if the creation fails, the access-list change should not be rolled
    # back EIP2929
    if c.fork >= FkBerlin:
      db.accessList(c.msg.contractAddress)

  c.snapshot()

  if c.vmState.readOnlyStateDb().hasCodeOrNonce(c.msg.contractAddress):
    var blurb =c.msg.contractAddress.toHex
    c.setError("Address collision when creating contract address={blurb}", true)
    c.rollback()
    return true

  c.vmState.mutateStateDb:
    db.subBalance(c.msg.sender, c.msg.value)
    db.addBalance(c.msg.contractAddress, c.msg.value)
    db.clearStorage(c.msg.contractAddress)
    if c.fork >= FkSpurious:
      # EIP161 nonce incrementation
      db.incNonce(c.msg.contractAddress)

  return false

proc afterExecCreate(c: Computation) =
  if c.isSuccess:
    # This can change `c.isSuccess`.
    c.writeContract()
    # Contract code should never be returned to the caller.  Only data from
    # `REVERT` is returned after a create.  Clearing in this branch covers the
    # right cases, particularly important with EVMC where it must be cleared.
    if c.output.len > 0:
      c.output = @[]

  if c.isSuccess:
    c.commit()
  else:
    c.rollback()


proc beforeExec(c: Computation): bool =
  if not c.msg.isCreate:
    c.beforeExecCall()
    false
  else:
    c.beforeExecCreate()

proc afterExec(c: Computation) =
  if not c.msg.isCreate:
    c.afterExecCall()
  else:
    c.afterExecCreate()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc executeOpcodes*(c: Computation) =
  let fork = c.fork

  block:
    if not c.continuation.isNil:
      c.continuation = nil
    elif c.execPrecompiles(fork):
      break

    try:
      c.selectVM(fork)
    except CatchableError as e:
      c.setError(
        &"Opcode Dispatch Error msg={e.msg}, depth={c.msg.depth}", true)

  if c.isError() and c.continuation.isNil:
    if c.tracingEnabled: c.traceError()
    #trace "executeOpcodes error", msg=c.error.info


proc execCallOrCreate*(cParam: Computation) =
  var (c, before) = (cParam, true)
  defer:
    while not c.isNil:
      c.dispose()
      c = c.parent

  # No actual recursion, but simulate recursion including before/after/dispose.
  while true:
    while true:
      if before and c.beforeExec():
        break
      c.executeOpcodes()
      if c.continuation.isNil:
        c.afterExec()
        break
      (before, c.child, c, c.parent) = (true, nil.Computation, c.child, c)
    if c.parent.isNil:
      break
    c.dispose()
    (before, c.parent, c) = (false, nil.Computation, c.parent)
    (c.continuation)()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
