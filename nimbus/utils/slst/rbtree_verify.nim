# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./rbtree_desc,
  stew/results

type
  RbLtFn*[C] = ##\
    ## Compare two data containers (rather than a container against a key)
    ## for the equivalent of `a < b`
    proc(a, b: C): bool {.gcsafe.}

  RbPrnFn* = ##\
    ## Handle error message
    proc(code: RbInfo; ctxInfo: string)
      {.gcsafe, raises: [Defect,CatchableError].}

  RbDdebug[C,K] = object
    tree: RbTreeRef[C,K]     ## tree, not-Nil
    node: RbNodeRef[C]       ## current node
    level: int               ## red + black recursion level
    blkLevel: int            ## black recursion level
    blkDepth: int            ## expected black node chain length (unless zero)
    lt: RbLtFn[C]            ## vfy less than
    pr: RbPrnFn
    msg: string              ## collect data

{.push raises: [Defect].}

# ----------------------------------------------------------------------- ------
# Private
# ------------------------------------------------------------------------------

proc pp[C](n: RbNodeRef[C]): string =
  if n.isNil:
    return "nil"
  result = $n.casket
  if n.isRed:
    result &= "~red"
  else:
    result &= "~black"

proc doError[C,K](d: var RbDdebug[C,K]; t: RbInfo; s: string):
                   Result[void,(C,RbInfo)]
                    {.gcsafe, raises: [Defect,CatchableError].} =
  if not d.pr.isNil:
    var msg = s &
      ": <" & d.node.pp &
      " link[" & d.node.linkLeft.pp &
      ", " & d.node.linkRight.pp & "]>"
    d.pr(t, msg)
  err((d.node.casket,t))

proc rootIsRed[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyRootIsRed, "Root node is red")


proc redNodeRedLinkLeft[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyRedParentRedLeftLink, "Parent node and left link red")

proc redNodeRedLinkRight[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyRedParentRedRightLink, "Parent node and right link red")

proc redNodeRedLinkBoth[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyRedParentRedBothLinks, "Parent node and both links red")


proc linkLeftCompError[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyLeftLinkGtParent, "Left node greater than parent")

proc linkRightCompError[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyRightLinkLtParent, "Right node greater than parent")

proc linkBothCompError[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyBothLinkCmpParentReversed,
            "Left node greater than parent greater than right node")

proc blackChainLevelError[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  d.doError(rbVfyBlackChainLevelMismatch,
            "Inconsistent length of black node chains")


proc subTreeVerify[C,K](d: var RbDdebug[C,K]): Result[void,(C,RbInfo)]
                         {.gcsafe, raises: [Defect,CatchableError].} =
  let node = d.node
  doAssert not node.isNil

  # Check for double red link violation
  if node.isRed:
    if node.linkLeft.isRed:
      if node.linkRight.isRed:
        return d.redNodeRedLinkBoth
      return d.redNodeRedLinkLeft
    if node.linkRight.isRed:
      return d.redNodeRedLinkRight

  # ok node is black, check the values if `lt` is available
  if not d.lt.isNil:

    let
      linkLeft = node.linkLeft
      leftOk = linkLeft.isNil or d.lt(linkLeft.casket,node.casket)

      linkRight = node.linkRight
      rightOk = linkRight.isNil or d.lt(node.casket,linkRight.casket)

    if not leftOk:
      if not rightOk:
        return d.linkBothCompError
      return d.linkLeftCompError

    if not rightOk:
      return d.linkRightCompError

  # update nesting level and black chain length
  d.level.inc
  if not node.isRed:
    d.blkLevel.inc

  if node.linkLeft.isNil and node.linkRight.isNil:
    # verify black chain length
    if d.blkDepth == 0:
      d.blkDepth = d.blkLevel
    elif d.blkDepth != d.blkLevel:
      return d.blackChainLevelError

  if not node.linkLeft.isNil:
    d.node = node.linkLeft
    let rc = d.subTreeVerify
    if rc.isErr:
      return rc ;

  if not node.linkRight.isNil:
    d.node = node.linkRight
    let rc = d.subTreeVerify
    if rc.isErr:
      return rc ;

  d.level.dec
  if not node.isRed:
    d.blkLevel.dec

  ok()

# ----------------------------------------------------------------------- ------
# Public
# ------------------------------------------------------------------------------

proc rbTreeVerify*[C,K](rbt: RbTreeRef[C,K];
                        lt: RbLtFn[C] = nil; pr: RbPrnFn = nil):
                          Result[void,(C,RbInfo)]
                            {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verifies the argument tree `rbt` for
  ## * No consecutively linked red nodes down the tree
  ## * Link consisteny: value(leftLink) < value(node) < value(rightLink). This
  ##   check needs to have the argument `lt` defined, otherwise this check is
  ##   skipped
  ## * Black length: verify that all node chains down the tree count the same
  ##   lengths
  ##
  ## The function returns `rbOk` unless an error is found. If `pr` is defined,
  ## this function is called with some error code and context information.
  if rbt.root.isNil:
    return ok()

  var d = RbDdebug[C,K](
    tree: rbt,
    node: rbt.root,
    lt:   lt,
    pr:   pr)

  if rbt.root.isRed:
    return d.rootIsRed

  d.subTreeVerify

# ----------------------------------------------------------------------- ------
# End
# ------------------------------------------------------------------------------
