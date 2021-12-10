# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Generic Red-black Tree
## ======================
##
## This `red-black <https://en.wikipedia.org/wiki/Red–black_tree>`_ tree
## library was inspired by Julienne Walker's excellent tutorial,
## captured `here <https://archive.is/miDT>`_ or
## `here <https://web.archive.org/web/20180706105528/http://eternallyconfuzzled.com/tuts/datastructures/jsw_tut_rbtree.aspx>`_.
## The downloadable C library has been captured
## `here <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
##
## In a nutshell,t a *red-black tree* emulates a *b-tree* by replacing a
## b-tree node
## ::
##   |       a, b, c
##   |      /  |  |  \
##
## by red or black colored binary nodes
## ::
##   |             b
##   |          <black>
##   |      a  /       \  c
##   |    <red>         <red>
##   |    /   \         /   \
##
## So, apart from insert and delete operations which are basically masked
## *b-tree* operations, search and traversal tools for binary trees can be
## used for *red-black trees* as well.
##
## Red-black tree module interface components
## ------------------------------------------
##
## :C:
##    Opaque data type: It is a comparable contents or data container derived
##    from a key data item of type `K` (see comments on `RbMkcFn` type.) This
##    data type `C` must be an object *reference*.
##
## :K:
##    Opaque index type: It is used to identify and retrieve some data
##    container of type `C`.
##

# Historic ackn:
#  http://eternallyconfuzzled.com/libs/jsw_rbtree.zip (now defunct)
#
# Original copyright notice from jsw_rbtree.h:
#    > Created (Julienne Walker): August 23, 2003
#    > Modified (Julienne Walker): March 14, 2008
#
#   This code is in the public domain. Anyone may
#   use it or change it in any way that they see
#   fit. The author assumes no responsibility for
#   damages incurred through use of the original
#   code or any variations thereof.
#
#   It is requested, but not required, that due
#   credit is given to the original author and
#   anyone who has modified the code through
#   a header comment, such as this one.typedef

import
  std/[tables],
  stew/results

const
  rbTreeReBalancedFlag* = 1
  rbTreeNodesDeletedFlag* = 2
  rbTreeFlushDataFlag* = 4

type
  RbCmpFn*[C,K] = ##\
    ## A function of this type compares a `casket` argument against the `key` \
    ## argument.
    ## The function returns either zero, a positive, or a negaitve integer not
    ## unlike `cmp()` for integers or strings. This type of function is used
    ## for organising the red-black tree in a sorted manner.
    proc(casket: C; key: K): int {.gcsafe.}

  RbMkcFn*[C,K] = ##\
    ## A function of this type creates a new object `C` from argument key `K`.
    ## Given a pair of functions `(cmp,mkc)` of respective types
    ## `(RbCmpFn,RbMkcFn)`, the function `mkc` must satisfy
    ## ::
    ##   cmp(mkc(key),key) == 0
    ##
    ## which is taken for granted and *not* verified by the red-black tree
    ## functions. Also, `mkc()` must be injective, i.e.
    ## ::
    ##   key != key'  =>  mkc(key) != mkc(key')
    ##
    ## Once generated, the value `mkc(key)` of type `C` will be made
    ## accessible by the API so that it can be modified but it must be made
    ## certain that no modification changes the reverse image of `mkc()`,
    ## i.e. for every modification `mod:C -> C` the following must hold
    ## ::
    ##   cmp(mod(mkc(key)),key) == 0
    ##
    ## A trivial example for `mkc()` would be to return a copy of the argument
    ## key and consider it read-only.
    proc(key: K): C {.gcsafe.}

  RbInfo* = enum ##\
    ## Used as code error compinent in `RbResult` function return code.
    rbOk = 0                           ## Seldom used (mainly for debugging)
    rbFail                             ## Just failed something
    rbEmptyTree                        ## No data yet
    rbNotFound                         ## No matching entry
    rbExists                           ## Could not insert as new entry

    rbEndOfWalk                        ## All nodes visited
    rbWalkClosed                       ## This walk has been closed
    rbWalkBlocked                      ## Tree changed while walking

    rbVfyRootIsRed                     ## Debug: Root node is red
    rbVfyRedParentRedLeftLink          ## ..
    rbVfyRedParentRedRightLink
    rbVfyRedParentRedBothLinks
    rbVfyLeftLinkGtParent
    rbVfyRightLinkLtParent
    rbVfyBothLinkCmpParentReversed
    rbVfyBlackChainLevelMismatch

  RbDir* = enum ##\
    ## Node link direction, array index.
    ## The red-black tree implementation here also requires implicit colour
    ## value encodings `false` for black and `true` for red (see getters
    ## `isRed()`, `toDir()`, `not()`, and the `isRed=()` setter.)
    rbLeft = 0
    rbRight = 1

  RbResult*[C] = ##\
    ## Combined function return code, data value or errror code.
    Result[C,RbInfo]

  RbNodeRef*[C] = ref object ##\
    ## Node with value container, main component of a red-black tree.
    ## These nodes build up the red-black tree (see
    ## `eternally confuzzled <https://archive.is/miDT>`_.)
    redColour: bool                    ## Algorithm dependent colour marker
    link*:array[RbDir,RbNodeRef[C]]    ## Left and right tree links, vertex
    casket*: C                         ## Comparable node data container

  RbTreeRef*[C,K] = ref object of RootObj ##\
    ## Red-black tree descriptor object
    cmpFn: RbCmpFn[C,K]                ## Comparison handler
    mkcFn: RbMkcFn[C,K]                ## Pseudo-dup handler
    root*: RbNodeRef[C]                ## Top of the tree
    cache*: RbNodeRef[C]               ## Last node created, found etc.
    size*: int                         ## Number of node items
    dirty*: int                        ## Reset walk while tree is manipulated
    walkIdGen: uint                    ## Id generaror for walks[] table
    walks*: Table[uint,RbWalkRef[C,K]] ## Open walk descriptors list

  RbWalkRef*[C,K] = ref object of RootObj ##\
    ## Traversal descriptor for a red-black tree
    id*: uint                          ## walks[] table registry
    tree*: RbTreeRef[C,K]              ## Paired tree
    node*: RbNodeRef[C]                ## Current node
    path*: seq[RbNodeRef[C]]           ## Traversal path
    top*: int                          ## Top of stack
    start*: bool                       ## `true` after a rewind operation
    stop*: bool                        ## End of traversal

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc newRbTreeRef*[C,K](cmp: RbCmpFn[C,K]; mkc: RbMkcFn[C,K]): RbTreeRef[C,K] =
  ## Constructor. Create generic red-black tree descriptor for data container
  ## type `C` and key type `K`. Details about the function arguments `cmpFn`
  ## and `mkcFn` are documented with the type definitions of `RbCmpFn` and
  ## `RbMkcFn`.
  RbTreeRef[C,K](
    cmpFn: cmp,
    mkcFn: mkc,
    walkIdGen: 1, # next free ID
    walks: initTable[uint,RbWalkRef[C,K]](1))


proc newWalkId*[C,K](rbt: RbTreeRef[C,K]): uint {.inline.} =
  ## Generate new free walk ID, returns zero in (theoretical) case all other
  ## IDs are exhausted.
  for id in rbt.walkIdGen .. rbt.walkIdGen.high:
    if not rbt.walks.hasKey(id):
      rbt.walkIdGen = id
      return id
  for id in 1u ..< rbt.walkIdGen:
    if not rbt.walks.hasKey(id):
      rbt.walkIdGen = id
      return id
  0

# ------------------------------------------------------------------------------
# Public handlers
# ------------------------------------------------------------------------------

proc cmp*[C,K](rbt: RbTreeRef[C,K]; casket: C; key: K): int {.inline.} =
  ## See introduction for an explanation of opaque argument types `C` and `D`,
  ## and the type definition for `RbCmpFn` for properties of this function.
  rbt.cmpFn(casket, key)

proc mkc*[C,K](rbt: RbTreeRef[C,K]; key: K): C {.inline.} =
  ## See introduction for an explanation of opaque argument/return types `C`
  ## and `D`, and the type definition for `RbMkdFn` for properties of this
  ## function.
  rbt.mkcFn(key)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc linkLeft*[C](node: RbNodeRef[C]): RbNodeRef[C] {.inline.} =
  ## Getter, shortcut for `node.link[rbLeft]`
  node.link[rbLeft]

proc linkRight*[C](node: RbNodeRef[C]): RbNodeRef[C] {.inline.} =
  ## Getter, shortcut for `node.link[rbRight]`
  node.link[rbRight]

proc isRed*[C](node: RbNodeRef[C]): bool {.inline.} =
  ## Getter, `true` if node colour is read.
  not node.isNil and node.redColour

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `linkLeft=`*[C](node, child: RbNodeRef[C]) {.inline.} =
  ## Getter, shortcut for `node.link[rbLeft] = child`
  node.link[rbLeft] = child

proc `linkRight=`*[C](node, child: RbNodeRef[C]) {.inline.} =
  ## Getter, shortcut for `node.link[rbRight] = child`
  node.link[rbRight] = child

proc `isRed=`*[C](node: RbNodeRef[C]; value: bool) {.inline.} =
  ## Setter, `true` sets red node colour.
  node.redColour = value

# ------------------------------------------------------------------------------
# Public helpers: `rbDir` as array index
# ------------------------------------------------------------------------------

proc `not`*(d: RbDir): RbDir {.inline.} =
  ## Opposite direction of argument `d`.
  if d == rbLeft: rbRight else: rbLeft

proc toDir*(b: bool): RbDir {.inline.} =
  ## Convert to link diection `rbLeft` (false) or `rbRight` (true).
  if b: rbRight else: rbLeft

# ------------------------------------------------------------------------------
# Public pretty printer
# ------------------------------------------------------------------------------

proc `$`*[C](node: RbNodeRef[C]): string =
  ## Pretty printer, requres `$()` for type `C` to be known.
  if node.isNil:
    return "nil"
  proc colour(red: bool): string =
    if red: "red" else: "black"
  "(" &
    node.isRed.colour & "," &
    $node.casket & "," &
    "left=" & $node.linkLeft & "," &
    "right=" & $node.linkRight  & ")"

proc `$`*[C,K](rbt: RbTreeRef[C,K]): string =
  ## Pretty printer
  if rbt.isNil:
    return "nil"
  "[" &
    "size=" & $rbt.size & "," &
    "gen=" & $rbt.walkIdGen & "," &
    "root=" & $rbt.root & "]"

proc `$`*[C,K](w: RbWalkRef[C,K]): string =
  ## Pretty printer
  if w.isNil:
    return "nil"
  result = "[id=" & $w.id
  if w.tree.isNil:
    result &= ",tree=nil"
  if w.node.isNil:
    result &= ",node=nil"
  else:
    result &= ",node=" & $w.node.casket
  result &= ",path.len=" & $w.path.len
  if w.start:
    result &= ",start"
  if w.stop:
    result &= ",stop"
  result &= "]"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
