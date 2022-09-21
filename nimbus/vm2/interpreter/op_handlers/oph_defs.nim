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

import
  chronos,
  options,
  ../../types,
  ../../../forks,
  ../op_codes,
  eth/common/eth_types

type
  Vm2Ctx* = tuple
    cpt: Computation          ## computation text
    rc: int                   ## return code from op handler

  Vm2OpFn* =                  ## general op handler, return codes are passed
                              ## back via argument descriptor ``k``
    proc(k: var Vm2Ctx) {.gcsafe.}

  # AARDVARK - does the gcsafe pragma make any sense here? I don't
  # really understand how gcsafe interacts with async. --Adam
  Vm2AsyncOpFn* =             ## here's the async version
    proc(k: var Vm2Ctx): Future[void] {.gcsafe.}

  Vm2OpHandlers* = tuple   ## three step op code execution, typically
                           ## only the ``run`` entry is activated
    prep: Vm2OpFn
    run:  Vm2OpFn
    post: Vm2OpFn

  # AARDVARK - I'm still not sure whether it makes sense to have this
  # tuple with async versions of prep and post too, or whether all I
  # need is an asynchronouslyRun field in the Vm2OpHandlers tuple.
  Vm2AsyncOpHandlers* = tuple
    prep: Vm2AsyncOpFn
    run:  Vm2AsyncOpFn
    post: Vm2AsyncOpFn

  Vm2OpExec* = tuple          ## op code handler entry
    opCode: Op                ## index back-reference
    forks: set[Fork]          ## forks applicable for this operation
    name: string              ## handler name
    info: string              ## handter info, explainer
    exec: Vm2OpHandlers       ## handlers to be used if synchronous
    asyncHandlers: Option[Vm2AsyncOpHandlers] ## if asynchronous


# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

const
  vm2OpIgnore*: Vm2OpFn =                ## No operation, placeholder function
    proc(k: var Vm2Ctx) = discard

  vm2AsyncOpIgnore*: Vm2AsyncOpFn =      ## No operation, placeholder function
    proc(k: var Vm2Ctx): Future[void] = newCompletedVoidFuture()

  vm2NoAsyncOpHandlers*: Option[Vm2AsyncOpHandlers] =
    none[Vm2AsyncOpHandlers]()
  
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

  Vm2OpLondonAndLater* =
    Vm2OpBerlinAndLater - {FkBerlin}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
