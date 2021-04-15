# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Helper Functions & Macros
## ==============================================
##

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ./oph_defs,
  macros,
  stint

type
  OphNumToTextFn* = proc(n: int): string
  OpHanldlerImplFn* = proc(k: Vm2Ctx; n: int)

const
  recForkSet = "Vm2OpAllForks"

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../db/accounts_cache,
    ../../v2state,
    ../../v2types,
    ../gas_meter,
    ../v2gas_costs,
    eth/common

else:
  const
    emvcStatic = 1
    ColdAccountAccessCost = 2
    WarmStorageReadCost = 3

  type
    GasInt = int

  # function stubs from v2state.nim
  template mutateStateDB(vmState: BaseVMState, body: untyped) =
    block:
      var db {.inject.} = vmState.accountDb
      body

  # function stubs from accounts_cache.nim:
  func inAccessList[A,B](ac: A; address: B): bool = false
  proc accessList[A,B](ac: var A, address: B) = discard

  # function stubs from gas_meter.nim
  proc consumeGas(gasMeter: var GasMeter; amount: int; reason: string) = discard

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc asIdent(id, name: string): NimNode {.compileTime.} =
  result = nnkExprColonExpr.newTree(
             newIdentNode(id),
             newIdentNode(name))

proc asText(id, name: string): NimNode {.compileTime.} =
  result = nnkExprColonExpr.newTree(
             newIdentNode(id),
             newLit(name))

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc gasEip2929AccountCheck*(c: Computation;
                             address: EthAddress, prevCost = 0.GasInt) =
  c.vmState.mutateStateDB:
    let gasCost = if not db.inAccessList(address):
                    db.accessList(address)
                    ColdAccountAccessCost
                  else:
                    WarmStorageReadCost

    c.gasMeter.consumeGas(
      gasCost - prevCost,
      reason = "gasEIP2929AccountCheck")


template checkInStaticContext*(c: Computation) =
  ## Verify static context in handler function, raise an error otherwise
  if emvcStatic == c.msg.flags:
    # TODO: if possible, this check only appear
    # when fork >= FkByzantium
    raise newException(
      StaticContextError,
      "Cannot modify state while inside of STATICCALL context")


macro genOphHandlers*(runHandler: static[OphNumToTextFn];
                      itemInfo: static[OphNumToTextFn];
                      inxList: static[openArray[int]];
                      body: static[OpHanldlerImplFn]): untyped =
  ## Generate the equivalent of
  ## ::
  ##  const <runHandler>: Vm2OpFn = proc (k: Vm2Ctx) =
  ##    ## <itemInfo(n)>,
  ##    <body(k,n)>
  ##
  ## for all `n` in `inxList`
  ##
  result = newStmtList()

  for n in inxList:
    let
      fnName = ident(n.runHandler)
      comment = newCommentStmtNode(n.itemInfo)

    # => push##Op: Vm2OpFn = proc (k: Vm2Ctx) = ...
    result.add quote do:
      const `fnName`: Vm2OpFn = proc(k: Vm2Ctx) =
        `comment`
        `body`(k,`n`)
  # echo ">>>", result.repr


macro genOphList*(runHandler: static[OphNumToTextFn];
                  handlerInfo: static[OphNumToTextFn];
                  inxList: static[openArray[int]];
                  varName: static[string];
                  opCode: static[OphNumToTextFn]): untyped =
  ## Generate
  ## ::
  ##   const <varName>*: seq[Vm2OpExec] = @[ <records> ]
  ##
  ## where <records> is a sequence of <record(n)> items like
  ## ::
  ##   (opCode: <opCode(n)>,
  ##    forks: Vm2OpAllForks,
  ##    info: <handlerInfo(n)>,
  ##    exec: (prep: vm2OpIgnore,
  ##           run: <runHandler(n)>,
  ##           post: vm2OpIgnore))
  ##
  ## for all `n` in `inxList`
  ##
  var records = nnkBracket.newTree()
  for n in inxList:
    records.add nnkPar.newTree(
                  "opCode".asIdent(n.opCode),
                  "forks".asIdent(recForkSet),
                  "info".asText(n.handlerInfo),
                  nnkExprColonExpr.newTree(
                    newIdentNode("exec"),
                    nnkPar.newTree(
                      "prep".asIdent("vm2OpIgnore"),
                      "run".asIdent(n.runHandler),
                      "post".asIdent("vm2OpIgnore"))))

  # => const <varName>*: seq[Vm2OpExec] = @[ <records> ]
  result = nnkStmtList.newTree(
             nnkConstSection.newTree(
               nnkConstDef.newTree(
                 nnkPostfix.newTree(
                   newIdentNode("*"),
                   newIdentNode(varName)),
                 nnkBracketExpr.newTree(
                   newIdentNode("seq"),
                   newIdentNode("Vm2OpExec")),
                 nnkPrefix.newTree(
                   newIdentNode("@"), records))))
  # echo ">>> ", result.repr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

