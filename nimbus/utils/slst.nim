# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Generic Sorted List Based on Red-black Trees
## ============================================
##
## Due to the sort order fetch operations ge, le, etc., this API differs
## considerably from the `table` API.
##
## Note that the list descriptor is a reference. So assigning an `sLstRef`
## descriptor variable does *not* duplicate the descriptor but rather
## add another link to the descriptor.
##
## Example:
## ::
##  # create new list with integer keys, and integer values
##  var sl = newSLst[int,int]()
##
##  # add some entries
##  for key in [208, 127, 106, 117,  49,  40, 171]:
##    let rc = sl.insert(key)
##    if rc.isOk:
##      # unique key, store some value
##      rc.value.data = -key
##
##  # print entries with keys greater than 100 in natrual key order
##  block:
##    var rc = sl.ge(100)
##    while rc.isOk:
##      echo "*** item ", rc.value.key, " ",  rc.value.data
##      w = sl.gt(w.value.key)
##
##  # print all key/value entries in natrual key order
##  block:
##    var
##      walk = sl.newWalk
##      rc = w.first
##    while rc.isOk:
##      echo "*** item ", rc.value.key, " ",  rc.value.data
##      rc = w.next
##    # optional clan up, see comments on `rbWalkDestroy()`
##    walk.destroy
##
import
  std/[tables],
  ./slst/[rbtree_delete,
          rbtree_desc,
          rbtree_find,
          rbtree_flush,
          rbtree_insert,
          rbtree_reset,
          rbtree_verify,
          rbtree_walk],
  stew/results

export
  RbInfo,
  RbResult,
  `isRed=`, # no need to export all of `rbtree_desc`
  results

type
  SLstItemRef*[K,V] = ref object ##\
    ## Data value container as stored in the list/database
    key: K                    ## Sorter key, read-only
    data*: V                  ## Some data value, to be modified freely

  SLst*[K,V] = object of RootObj ##\
    ## Sorted list descriptor
    tree: RbTreeRef[SLstItemRef[K,V],K]

  SLstWalkRef*[K,V] = ##\
    ## Traversal/walk descriptor for sorted list
    RbWalkRef[SLstItemRef[K,V],K]

  SLstResult*[K,V] = ##\
    ## Data value container or error code, typically used as value \
    ## returned from functions.
    RbResult[SLstItemRef[K,V]]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc slstCmp[K,V](casket: SLstItemRef[K,V]; key: K): int =
  casket.key.cmp(key)

proc slstMkc[K,V](key: K): SLstItemRef[K,V] =
  SLstItemRef[K,V](key: key)

proc slstClup[K,V](c: var SLstItemRef[K,V]) =
  # ... some smart stuff here?
  c = nil     # GC hint (if any, todo?)


proc slstLt[K,V](a, b: SLstItemRef[K,V]): bool =
  ## Debugging only
  a.slstCmp(b.key) < 0

proc slstPr(code: RbInfo; ctxInfo: string) =
  ## Debugging only
  echo "*** sLst Error(", code, "): ", ctxInfo

# ------------------------------------------------------------------------------
# Public helpers, debugging
# ------------------------------------------------------------------------------

proc `$`*[K,V](casket: SLstItemRef[K,V]): string =
  ## Pretty printer
  ##
  ## :CAVEAT:
  ##   This function needs a working definition for the `data` item:
  ##   ::
  ##    proc `$`*[V](value: V): string {.gcsafe,raises:[Defect,CatchableError].}
  ##
  if casket.isNil:
    return "nil"
  "(" & $casket.key & "," & $casket.data & ")"

proc `$`*[K,V](rc: SLstResult[K,V]): string =
  ## Pretty printer
  ##
  ## :CAVEAT:
  ##   This function needs a working definition for the `data` item:
  ##   ::
  ##    proc `$`*[V](data: V): string {.gcsafe,raises:[Defect,CatchableError].}
  ##
  if rc.isErr:
    return $rc.error
  $rc.value

proc verify*[K,V](sl: var SLst[K,V]):
                  Result[void,(SLstItemRef[K,V],RbInfo)]
                    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Check for consistency, may print an error message. Returns `rbOk` if
  ## the argument list `sl` is consistent.
  ##
  ## :CAVEAT:
  ##   This function needs a working definition for the `data` item:
  ##   ::
  ##    proc `$`*[V](data: V): string {.gcsafe,raises:[Defect,CatchableError].}
  ##
  sl.tree.rbTreeVerify(
    lt = proc(a, b: SLstItemRef[K,V]): bool = a.sLstLt(b),
    pr = proc(c: RbInfo; s: string) = c.slstPr(s))

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*[K,V](sl: var SLst[K,V]) =
  ## Constructor for sorted list with key type `K` and data type `V`
  sl.tree = newRbTreeRef[SLstItemRef[K,V],K](
    cmp = proc(c: SLstItemRef[K,V]; k: K): int = c.slstCmp(k),
    mkc = proc(k: K): SLstItemRef[K,V] = slstMkc[K,V](k))

proc init*[K,V](T: type SLst[K,V]): T =
  ## Variant of `init()`
  result.init

proc move*[K,V](sl: var SLst[K,V]): SLst[K,V] =
  ## Return a shallow copy of the argument list `sl`, then reset `sl`.
  result.tree = sl.tree
  sl.init

proc reset*[K,V](sl: var SLst[K,V]) =
  ## Reset list descriptor to its inital value. This function also de-registers
  ## and flushes all traversal descriptors of type `SLstWalkRef`.
  sl.tree.rbTreeReset(clup = proc(c: var SLstItemRef[K,V]) = c.slstClup)

# ------------------------------------------------------------------------------
# Public functions, getter, converter
# ------------------------------------------------------------------------------

proc key*[K,V](data: SLstItemRef[K,V]): K =
  ## Getter, extracts the key from the data container item.
  data.key

proc len*[K,V](sl: var SLst[K,V]): int =
  ## Number of list elements
  sl.tree.size

proc toSLstResult*[K,V](key: K; data: V): SLstResult[K,V] =
  ## Helper, chreate `ok()` result
  ok(SLstItemRef[K,V](key: key, data: data))

# ------------------------------------------------------------------------------
# Public functions, list operations
# ------------------------------------------------------------------------------

proc insert*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Insert `key`, returns data container item with the `key`. Function fails
  ## if `key` exists in the list.
  sl.tree.rbTreeInsert(key)

proc findOrInsert*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Insert or find `key`, returns data container item with the `key`. This
  ## function always succeeds (unless there is s problem with the list.)
  result = sl.tree.rbTreeInsert(key)
  if result.isErr:
    return sl.tree.rbTreeFindEq(key)

proc delete*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Delete `key` from list and return the data container item that was
  ## holding the `key` if it was deleted.
  sl.tree.rbTreeDelete(key)

proc flush*[K,V](sl: var SLst[K,V]) =
  ## Flush the sorted list, i.e. delete all entries. This function is
  ## more efficient than running a `delete()` loop.
  sl.tree.rbTreeFlush(clup = proc(c: var SLstItemRef[K,V]) = c.slstClup)

# ------------------------------------------------------------------------------
# Public functions, query functions
# ------------------------------------------------------------------------------

proc eq*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Find `key` in list, returns data container item with the `key` if it
  ## exists.
  sl.tree.rbTreeFindEq(key)

proc le*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Find data container iten with *largest* key *less or equal* the argument
  ## `key` in list and return it if found.
  sl.tree.rbTreeFindLe(key)

proc lt*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Find data container item with *largest* key *less than* the argument
  ## `key` in list and return it if found.
  sl.tree.rbTreeFindLt(key)

proc ge*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Find data container item with *smallest* key *greater or equal* the
  ## argument `key` in list and return it if found.
  sl.tree.rbTreeFindGe(key)

proc gt*[K,V](sl: var SLst[K,V]; key: K): SLstResult[K,V] =
  ## Find data container item with *smallest* key *greater than* the argument
  ## `key` in list and return it if found.
  sl.tree.rbTreeFindGt(key)

# ------------------------------------------------------------------------------
# Public functions, walk/traversal functions
# ------------------------------------------------------------------------------

proc newWalk*[K,V](sl: var SLst[K,V]): SLstWalkRef[K,V] =
  ## Open traversal descriptor on list and register it on the 'SLst`
  ## descriptor.
  sl.tree.newRbWalk

proc destroy*[K,V](w: SLstWalkRef[K,V]) =
  ## De-register and close the traversal descriptor. This function renders
  ## the descriptor unusable, so it must be disposed of.
  ##
  ## This destructor function is crucial when insert/delete operations are
  ## needed to run while traversals are open and not rewound. These
  ## insert/delete operations modify the list so that `w.this`, `w.prev`,
  ## etc. operations might fail. All traversal descriptors must then be
  ## rewound or destroyed.
  w.rbWalkDestroy

proc first*[K,V](w: SLstWalkRef[K,V]): SLstResult[K,V] =
  ## Rewind the traversal descriptor to the *least* list key and return
  ## the corresponding data container item.
  ##
  ## When all open traversals are rewound, blockers due to insert/delete
  ## list operations are reset.
  w.rbWalkFirst

proc last*[K,V](w: SLstWalkRef[K,V]): SLstResult[K,V] =
  ## Rewind the traversal descriptor to the *greatest* list key and return
  ## the corresponding data container item.
  ##
  ## When all open traversals are rewound, blockers due to insert/delete
  ## list operations are reset.
  w.rbWalkLast

proc this*[K,V](w: SLstWalkRef[K,V]): SLstResult[K,V] =
  ## Retrieve the *current* data container item. This is the same one retrieved
  ## last with any of the traversal functions returning the data container item.
  ##
  ## Note that the current node becomes unavailable if it was recently deleted.
  w.rbWalkCurrent

proc next*[K,V](w: SLstWalkRef[K,V]): SLstResult[K,V] =
  ## Move the traversal descriptor to the next *greater* key and return the
  ## corresponding data container item. If this is the first call after
  ## `newWalk()`, then `w.first` is called implicitly.
  ##
  ## If there were tree insert/delete operations, blockers might be active
  ## causing this function to fail so that a rewind is needed.
  w.rbWalkNext

proc prev*[K,V](w: SLstWalkRef[K,V]): SLstResult[K,V] =
  ## Move the traversal descriptor to the next *smaller* key and return the
  ## corresponding data container item . If this is the first call after
  ## `newWalk()`, then `w.last` is called implicitly.
  ##
  ## If there were tree insert/delete operations, blockers might be active
  ## causing this function to fail so that a rewind is needed.
  w.rbWalkPrev

# ------------------------------------------------------------------------------
# Public functions, relations
# ------------------------------------------------------------------------------

# ..

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
