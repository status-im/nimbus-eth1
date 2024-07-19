# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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

{.push raises: [].}

import ../../types, ../../../common/evmforks, ../../evm_errors, ../op_codes

type
  VmCpt* = Computation ## computation text

  VmOpFn* = ## general op handler, return codes are passed
    ## back via argument descriptor ``cpt``
    proc(cpt: VmCpt): EvmResultVoid {.nimcall, gcsafe, raises: [].}

  VmOpExec* =
    tuple
      ## op code handler entry
      opCode: Op ## index back-reference
      forks: set[EVMFork] ## forks applicable for this operation
      name: string ## handler name
      info: string ## handter info, explainer
      exec: VmOpFn

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

const
  VmOpIgnore*: VmOpFn = ## No operation, placeholder function
    proc(cpt: VmCpt): EvmResultVoid =
      ok()

  # similar to: toSeq(Fork).mapIt({it}).foldl(a+b)
  VmOpAllForks* = {EVMFork.low .. EVMFork.high}

  VmOpHomesteadAndLater* = ## Set of all fork symbols
    VmOpAllForks - {FkFrontier}

  VmOpTangerineAndLater* = ## Set of fork symbols starting from Homestead
    VmOpHomesteadAndLater - {FkHomestead}

  VmOpSpuriousAndLater* = ## ditto ...
    VmOpTangerineAndLater - {FkTangerine}

  VmOpByzantiumAndLater* = VmOpSpuriousAndLater - {FkSpurious}

  VmOpConstantinopleAndLater* = VmOpByzantiumAndLater - {FkByzantium}

  VmOpPetersburgAndLater* = VmOpConstantinopleAndLater - {FkConstantinople}

  VmOpIstanbulAndLater* = VmOpPetersburgAndLater - {FkPetersburg}

  VmOpBerlinAndLater* = VmOpIstanbulAndLater - {FkIstanbul}

  VmOpLondonAndLater* = VmOpBerlinAndLater - {FkBerlin}

  VmOpParisAndLater* = VmOpLondonAndLater - {FkLondon}

  VmOpShanghaiAndLater* = VmOpParisAndLater - {FkParis}

  VmOpCancunAndLater* = VmOpShanghaiAndLater - {FkShanghai}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
