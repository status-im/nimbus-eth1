# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
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
  ../../types,
  ../../../common/evmforks,
  ../op_codes

type
  Vm2Ctx* = tuple
    cpt: Computation          ## computation text

  Vm2OpFn* =                  ## general op handler, return codes are passed
                              ## back via argument descriptor ``k``
    proc(k: var Vm2Ctx) {.nimcall, gcsafe, raises: [CatchableError].}


  Vm2OpHanders* = tuple       ## three step op code execution, typically
                              ## only the ``run`` entry is activated
    prep: Vm2OpFn
    run:  Vm2OpFn
    post: Vm2OpFn


  Vm2OpExec* = tuple          ## op code handler entry
    opCode: Op                ## index back-reference
    forks: set[EVMFork]       ## forks applicable for this operation
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
    {EVMFork.low .. EVMFork.high}

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

  Vm2OpParisAndLater* =
    Vm2OpLondonAndLater - {FkLondon}

  Vm2OpShanghaiAndLater* =
    Vm2OpParisAndLater - {FkParis}

  Vm2OpCancunAndLater* =
    Vm2OpShanghaiAndLater - {FkShanghai}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
