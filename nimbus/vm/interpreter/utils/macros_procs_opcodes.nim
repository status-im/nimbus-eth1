# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# ##################################################################
# Macros to facilitate opcode procs creation

import
  macros,
  ../../computation, ../../stack,
  ../../../constants, ../../../vm_types

proc pop(tree: var NimNode): NimNode =
  ## Returns the last value of a NimNode and remove it
  result = tree[tree.len-1]
  tree.del(tree.len-1)

template letsGoDeeper =
  var rTree = node.kind.newTree()
  for child in node:
    rTree.add inspect(child)
  return rTree

proc replacePush(body, computation: NimNode): NimNode =
  # Args:
  #   - The computation ident node (= newIdentNode("computation"))
  #   - The proc body
  # Returns:
  #   - An AST with "push: foo" replaced by
  #     computation.stack.push(foo)

  proc inspect(node: NimNode): NimNode =
    case node.kind:
    of nnkCall:
      if eqIdent(node[0], "push"):
        let value = node[1]
        return quote do:
          `computation`.stack.push `value`
      else:
        letsGoDeeper()
    of {nnkIdent, nnkSym, nnkEmpty}:
      return node
    of nnkLiterals:
      return node
    else:
      letsGoDeeper()
  result = inspect(body)

macro op*(procname, fork: untyped, inline: static[bool], stackParams_body: varargs[untyped]): untyped =
  ## Usage:
  ## .. code-block:: nim
  ##   op add, FkFrontier, inline = true, lhs, rhs:
  ##     push:
  ##       lhs + rhs

  # TODO: Unfortunately due to varargs[untyped] consuming all following parameters,
  # we can't have a nicer macro signature `stackParams: varargs[untyped], body: untyped`
  # see https://github.com/nim-lang/Nim/issues/5855 and are forced to "pop"

  let computation = newIdentNode("computation")
  var stackParams = stackParams_body

  # 1. Separate stackParams and body with pop
  # 2. Replace "push: foo" by computation.stack.push(foo)
  let body = newStmtList().add stackParams.pop.replacePush(computation)

  # 3. let (x, y, z) = computation.stack.popInt(3)
  let len = stackParams.len
  var popStackStmt = nnkVarTuple.newTree()

  if len != 0:
    for params in stackParams:
      popStackStmt.add newIdentNode(params.ident)

    popStackStmt.add newEmptyNode()
    popStackStmt.add quote do:
      `computation`.stack.popInt(`len`)

    popStackStmt = nnkStmtList.newTree(
      nnkLetSection.newTree(popStackStmt)
    )
  else:
    popStackStmt = nnkDiscardStmt.newTree(newEmptyNode())

  # 4. Generate the proc with name addFkFrontier
  # TODO: replace by func to ensure no side effects
  #       pending - https://github.com/status-im/nim-stint/issues/52
  let procforkname = newIdentNode($procname & $fork)
  if inline:
    result = quote do:
      proc `procforkname`*(`computation`: var BaseComputation) {.inline.} =
        `popStackStmt`
        `body`
  else:
    result = quote do:
      proc `procforkname`*(`computation`: var BaseComputation) =
        `popStackStmt`
        `body`
