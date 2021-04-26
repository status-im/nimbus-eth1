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
  # help with low memory when compiling
  lowmem {.intdefine.}: int = 0
  lowMemoryCompileTime {.used.} = lowmem > 0

import
  ./code_stream,
  ./compu_helper,
  ./interpreter/op_dispatcher,
  ./types,
  chronicles

logScope:
  topics = "vm opcode"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc selectVM*(c: Computation, fork: Fork) {.gcsafe.} =
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
