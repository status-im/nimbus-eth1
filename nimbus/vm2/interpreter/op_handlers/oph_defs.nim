# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcodes, Definitions
## ========================
##
## Static exception filter strategy:
##
##   There is a general op handler type `Vm2OpFn` below which should throw
##   only `Defect` and `CatchableError` exceptions. Unfortunately, for several
##   reasons there are also `Exception` very base class exceptions. This
##   `Exception` class exception is considered uncatchable but as it is the
##   base class, it will be hard to filter it out without a run time delay
##   penalty.
##
##   In order to have at least some compile time exception tracking support,
##   there is a debugging mode compiler flag `-d:vm2_debug` which caused the
##   op handlers to run selected functions in a try/catch mode relaying the
##   `Exception` class exception to another, typically a `Defect` exception.

import
  ../../../errors,
  ../../../vm_compile_flags,
  ../../types,
  ../forks_list,
  ../op_codes,
  eth/common/eth_types

type
  Vm2Ctx* = tuple
    cpt: Computation          ## computation text
    # rc: int                 ## return code from op handler

when relay_exception_base_class:
  type
    Vm2OpFn* = proc(k: var Vm2Ctx) {.gcsafe, raises: [Defect,CatchableError].}
else:
  type
    Vm2OpFn* = proc(k: var Vm2Ctx) {.gcsafe, raises: [Exception].}

type
  Vm2OpHanders* = tuple       ## op code execution handlers, currently
                              ## only the ``run`` entry is executed.
    prep: Vm2OpFn
    run:  Vm2OpFn
    post: Vm2OpFn


  Vm2OpExec* = tuple          ## op code handler entry
    opCode: Op                ## index back-reference
    forks: set[Fork]          ## forks applicable for this operation
    name: string              ## handler name
    info: string              ## handter info, explainer
    exec: Vm2OpHanders

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

const
  vm2OpIgnore*: Vm2OpFn =      ## No operation, placeholder function
    proc(k: var Vm2Ctx) = discard

  # similar to: toSeq(Fork).mapIt({it}).foldl(a+b)
  Vm2OpAllForks* =
    {Fork.low .. Fork.high}

  Vm2OpHomesteadAndLater* =    ## Set of all fork symbols
    Vm2OpAllForks - {FkFrontier}

  Vm2OpTangerineAndLater* =    ## Set of fork symbols starting from Homestead
    Vm2OpHomesteadAndLater - {FkHomestead}

  Vm2OpSpuriousAndLater* =     ## ditto ...
    Vm2OpTangerineAndLater - {FkTangerine}

  Vm2OpByzantiumAndLater* =
    Vm2OpSpuriousAndLater - {FkSpurious}

  Vm2OpConstantinopleAndLater* =
    Vm2OpByzantiumAndLater - {FkByzantium}

  Vm2OpPetersburgAndLater* =
    Vm2OpConstantinopleAndLater - {FkConstantinople}

  Vm2OpIstanbulAndLater* =
    Vm2OpPetersburgAndLater - {FkPetersburg}

  Vm2OpBerlinAndLater* =
    Vm2OpIstanbulAndLater - {FkIstanbul}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
