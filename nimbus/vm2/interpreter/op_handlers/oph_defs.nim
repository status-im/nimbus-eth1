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

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../forks_list,
  ../op_codes,
  ../../memory_defs,
  ../../stack_defs,
  eth/common/eth_types

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../v2types
else:
  {.warning: "Circular dependency breaker kludge -- "&
             "no production code".}
  when defined(vm2_enabled):
    {.fatal: "Flag \"vm2_enabled\" must be unset "&
             "while circular dependency breaker kludge is activated".}
  type
    GasInt* = int

    ReadOnlyStateDB* =
      seq[byte]

    GasMeter* = object
      gasRemaining*: int

    CodeStream* = ref object
      bytes*: seq[byte]
      pc*: int

    BaseVMState* = ref object
      accountDb*: ReadOnlyStateDB

    Message* = ref object
      kind*: int
      depth*: int
      gas*: GasInt
      contractAddress*: EthAddress
      codeAddress*: EthAddress
      sender*: EthAddress
      value*: UInt256
      data*: seq[byte]
      flags*: int

    Computation* = ref object
      returnStack*: seq[int]
      output*: seq[byte]
      vmState*: BaseVMState
      gasMeter*: GasMeter
      stack*: Stack
      memory*: Memory
      msg*: Message
      code*: CodeStream
      returnData*: seq[byte]
      fork*: Fork
      parent*, child*: Computation
      continuation*: proc() {.gcsafe.}

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

export
  Op, Fork, Computation, Memory, Stack, UInt256, Message, EthAddress

type
  Vm2Ctx* = object of RootObj
    cpt*: Computation         ## computation text
    rc*: int                  ## return code from op handler

  Vm2OpFn* =                  ## general op handler, return codes are passed
                              ## back via argument descriptor ``k``
    proc(k: Vm2Ctx) {.gcsafe.}


  Vm2OpHanders* = tuple       ## three step op code execution, typically
                              ## only the ``run`` entry is activated
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
    proc(k: Vm2Ctx) = discard

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
