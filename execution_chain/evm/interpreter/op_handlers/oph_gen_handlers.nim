# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Macros For Generating OP Handlers
## ======================================================
##

import
  std/[strutils, macros],
  ./oph_defs,
  ../../evm_errors

type
  OphNumToTextFn* = proc(n: int): string

const
  recForkSet = "VmOpAllForks"

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

macro genOphHandlers*(runHandler: static[OphNumToTextFn];
                      itemInfo: static[OphNumToTextFn];
                      inxList: static[openArray[int]];
                      body: untyped): untyped =
  ## Generate the equivalent of
  ## ::
  ##  const <runHandler>: VmOpFn = proc(cpt: VmCpt) =
  ##    ## <itemInfo(n)>,
  ##    <body(cpt,n)>
  ##
  ## for all `n` in `inxList`
  ##
  result = newStmtList()

  for n in inxList:
    let
      fnName = ident(n.runHandler)
      comment = newCommentStmtNode(n.itemInfo)

    # => push##Op: VmOpFn = proc(cpt: VmCpt) = ...
    result.add quote do:
      proc `fnName`(cpt: VmCpt): EvmResultVoid =
        `comment`
        `body`(cpt,`n`)


macro genOphList*(runHandler: static[OphNumToTextFn];
                  handlerInfo: static[OphNumToTextFn];
                  inxList: static[openArray[int]];
                  varName: static[string];
                  opCode: static[OphNumToTextFn]): untyped =
  ## Generate
  ## ::
  ##   const <varName>*: seq[VmOpExec] = @[ <records> ]
  ##
  ## where <records> is a sequence of <record(n)> items like
  ## ::
  ##   (opCode: <opCode(n)>,
  ##    forks: VmOpAllForks,
  ##    info: <handlerInfo(n)>,
  ##    exec: <runHandler(n)>)
  ##
  ## for all `n` in `inxList`
  ##
  var records = nnkBracket.newTree()
  for n in inxList:
    var handlerName = n.runHandler.multiReplace(("Op",""),("OP",""))
    records.add nnkPar.newTree(
                  "opCode".asIdent(n.opCode),
                  "forks".asIdent(recForkSet),
                  "name".asText(handlerName),
                  "info".asText(n.handlerInfo),
                  nnkExprColonExpr.newTree(
                    newIdentNode("exec"),
                    newIdentNode(n.runHandler)))

  # => const <varName>*: seq[VmOpExec] = @[ <records> ]
  result = nnkStmtList.newTree(
             nnkConstSection.newTree(
               nnkConstDef.newTree(
                 nnkPostfix.newTree(
                   newIdentNode("*"),
                   newIdentNode(varName)),
                 nnkBracketExpr.newTree(
                   newIdentNode("seq"),
                   newIdentNode("VmOpExec")),
                 nnkPrefix.newTree(
                   newIdentNode("@"), records))))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

