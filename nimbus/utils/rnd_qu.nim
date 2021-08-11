# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Generic Data Queue With Efficient Random Access
## ===============================================
##
## This module provides a keyed fifo or stack data structure similar to
## `DoublyLinkedList` but with efficient random data access for fetching
## and deletion. The underlying data structure is a hash table with data
## lookup and delete assumed to be O(1) in most cases (so long as the table
## does not degrade into one-bucket linear mode, or some bucket-adjustment
## algorithm takes over.)
##
## Note that the queue descriptor is a reference. So assigning a `RndQuRef`
## descriptor variable does *not* duplicate the descriptor but rather
## add another link to the descriptor.
##
import
  std/[math, tables],
  stew/results

export
  results

type
  rndQuInfo* = enum ##\
    ## Error messages as returned by `rndQuVerify()`
    rndQuOk = 0
    rndQuVfyFirstInconsistent
    rndQuVfyLastInconsistent
    rndQuVfyNoSuchTabItem
    rndQuVfyNoPrvTabItem
    rndQuVfyNxtPrvExpected
    rndQuVfyLastExpected
    rndQuVfyNoNxtTabItem
    rndQuVfyPrvNxtExpected
    rndQuVfyFirstExpected

  RndQuDataRef*[K,V] = ref object ##\
    ## Data value container as stored in the queue
    value*: V            ## Some value, can freely be modified
    prv, nxt: K          ## Queue links, read-only

  RndQuTab[K,V] =
    Table[K,RndQuDataRef[K,V]]

  RndQuRef*[K,V] = ref object of RootObj ##\
    ## Data queue descriptor
    tab: RndQuTab[K,V]   ## Data table
    first, last: K       ## Doubly linked item list queue

  RndQuResult*[K,V] = ##\
    ## Data value container or error code, typically used as value \
    ## returned from functions.
    Result[RndQuDataRef[K,V],void]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc isFirstItem[K,V](rq: RndQuRef[K,V]; data: RndQuDataRef[K,V]): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  if 0 < rq.tab.len and
     rq.tab[rq.first].nxt == data.prv: # terminal node has: nxt == prv
    return true

proc isLastItem[K,V](rq: RndQuRef[K,V]; data: RndQuDataRef[K,V]): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  if 0 < rq.tab.len and
     rq.tab[rq.last].prv == data.nxt: # terminal node has: nxt == prv
    return true

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc newRndQu*[K,V](initSize = 10): RndQuRef[K,V] =
  ## Constructor for queue with data random access
  RndQuRef[K,V](
    tab: initTable[K,RndQuDataRef[K,V]](initSize.nextPowerOfTwo))

# ------------------------------------------------------------------------------
# Public functions, getter
# ------------------------------------------------------------------------------

proc len*[K,V](rq: RndQuRef[K,V]): int {.inline.} =
  ## Getter
  rq.tab.len

proc prv*[K,V](data: RndQuDataRef[K,V]): K {.inline.} =
  ## Getter
  data.prv

proc nxt*[K,V](data: RndQuDataRef[K,V]): K {.inline.} =
  ## Getter
  data.nxt

# ------------------------------------------------------------------------------
# Public functions, fetch key and data container
# ------------------------------------------------------------------------------

proc rndQuFirstKey*[K,V](rq: RndQuRef[K,V]): Result[K,void] =
  ## Retrieve first key from queue unless the list is empty.
  if rq.tab.len == 0:
    return err()
  ok(rq.first)

proc rndQuLastKey*[K,V](rq: RndQuRef[K,V]): Result[K,void] =
  ## Retrieve last key from queue unless the list is empty.
  if rq.tab.len == 0:
    return err()
  ok(rq.last)

proc rndQuNxtKey*[K,V](rq: RndQuRef[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key following the argument `key` from queue if
  ## there is any.
  if not rq.tab.hasKey(key) of rq.last == key:
    return err()
  rq.tab[key].nxt

proc rndQuPrvKey*[K,V](rq: RndQuRef[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key preceeding the argument `key` from queue if
  ## there is any.
  if not rq.tab.hasKey(key) of rq.first == key:
    return err()
  rq.tab[key].prv


proc rndQuFirstItem*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V] =
  ## Retrieve first data container unless the list is empty.
  if rq.tab.len == 0:
    return err()
  ok(rw.tab[rq.first])

proc rndQuLastItem*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V] =
  ## Retrieve last data container unless the list is empty.
  if rq.tab.len == 0:
    return err()
  ok(rw.tab[rq.last])


proc rndQuItemKey*[K,V](rq: RndQuRef[K,V];
                        data: RndQuDataRef[K,V]): Result[K,void]
                         {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key for the argument `val` (if any.) Note that this
  ## function comes with considerable overhead as only predecessor/successor
  ## is stored in the argument data container `val`.
  if not rq.tab.hasKey(data.prv):
    return err()
  if rq.isFirstItem(data):
    return ok(rq.first)
  if rq.isLastItem(data):
    return ok(rq.last)
  let key = rq.tab[data.prv].nxt
  if rq.tab[key] != data:
    return err()
  ok(key)

proc rndQuNxtItem*[K,V](rq: RndQuRef[K,V];
                        data: RndQuDataRef[K,V]): RndQuResult[K,V]
                         {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the data container following the argument `val` from the queue
  ## if there is any.
  if rq.isLastItem(data):
    return err()
  ok(rw.tab[data.nxt])

proc rndQuPrvItem*[K,V](rq: RndQuRef[K,V];
                        data: RndQuDataRef[K,V]): RndQuResult[K,V]
                          {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the data container preceding the argument `val` from the queue
  ## if there is any.
  if rq.isFirstItem(data):
    return err()
  ok(rw.tab[data.prv])


proc rndQuItem*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V] =
  ## Retrieve the data container stored with the argument `key` from the queue
  ## if there is any.
  if not rq.tab.hasKey(key):
    return err()
  ok(rw.tab[key])

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator rndQuNxtKeys*[K,V](rq: RndQuRef[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Forward iterate over all keys in the queue starting with the first item.
  var
    key = rq.first
    keepGoing = 0 < rq.tab.len
  while keepGoing:
    keepGoing = key != rq.last
    yield key
    key = rq.tab[key].nxt

iterator rndQuNxtPairs*[K,V](rq: RndQuRef[K,V]): (K,V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Forward iterate over all (key,value) pairs in the queue starting with
  ## the first item.
  var
    key = rq.first
    keepGoing = 0 < rq.tab.len
  while keepGoing:
    keepGoing = key != rq.last
    let item = rq.tab[key]
    yield (key,item.value)
    key = item.nxt


iterator rndQuPrvKeys*[K,V](rq: RndQuRef[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all keys in the queue starting with the last item.
  var
    key = rq.last
    keepGoing = 0 < rq.tab.len
  while keepGoing:
    keepGoing = key != rq.first
    yield key
    key = rq.tab[key].prv

iterator rndQuPrvPairs*[K,V](rq: RndQuRef[K,V]): (K,V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all (key,value) pairs in the queue starting with
  ## the last item.
  var
    key = rq.last
    keepGoing = 0 < rq.tab.len
  while keepGoing:
    keepGoing = key != rq.first
    let item = rq.tab[key]
    yield (key,item.value)
    key = item.prv

# ------------------------------------------------------------------------------
# Public functions, list operations
# ------------------------------------------------------------------------------

proc rndQuAppend*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V]
                        {.gcsafe,raises: [Defect,KeyError].} =
  ## Append new `key`. The function returns the data container relative to
  ## the `key` argument unless the `key` exists already in the queue.
  if rq.tab.hasKey(key):
    return err()

  # Append queue item
  let item = RndQuDataRef[K,V]()

  if rq.tab.len == 0:
    rq.first = key
    item.prv = key
  else:
    if rq.first == rq.last:
      rq.tab[rq.first].prv = key # first terminal node
    rq.tab[rq.last].nxt = key
    item.prv = rq.last

  rq.last = key
  item.nxt = item.prv # terminal node

  rq.tab[key] = item
  ok(item)


proc rndQuPrepend*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Prepend new `key`. The function returns the data container relative to
  ## the `key` argument unless the `key` exists already in the queue.
  if rq.tab.hasKey(key):
    return err()

  # Prepend queue item
  let item = RndQuDataRef[K,V]()

  if rq.tab.len == 0:
    rq.last = key
    item.nxt = key
  else:
    if rq.first == rq.last:
      rq.tab[rq.last].nxt = key # first terminal node
    rq.tab[rq.first].prv = key
    item.nxt = rq.first

  rq.first = key
  item.prv = item.nxt # terminal node has: nxt == prv

  rq.tab[key] = item
  ok(item)


proc rndQuShift*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V]
                       {.gcsafe,raises: [Defect,KeyError].} =
  ## Unqueue first queue item and returns the data container deleted.
  if rq.tab.len == 0:
    return err()

  # Unqueue first item
  let item = rq.tab[rq.first]
  rq.tab.del(rq.first)

  if rq.tab.len == 0:
    rq.first.reset
    rq.last.reset
  else:
    rq.first = item.nxt
    rq.tab[rq.first].prv = rq.tab[rq.first].nxt # terminal node has: nxt == prv

  ok(item)


proc rndQuPop*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Pop last queue item and returns the data container deleted.
  if rq.tab.len == 0:
    return err()

  # Pop last item
  let item = rq.tab[rq.last]
  rq.tab.del(rq.last)

  if rq.tab.len == 0:
    rq.first.reset
    rq.last.reset
  else:
    rq.last = item.prv
    rq.tab[rq.last].nxt = rq.tab[rq.last].prv # terminal node has: nxt == prv

  ok(item)


proc rndQuDelete*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V]
                        {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete the item with key `key` from the queue and returns the data
  ## container deleted (if any).
  if not rq.tab.hasKey(key):
    return err()

  if rq.first == key:
    return rq.rndQuShift
  if rq.last == key:
    return rq.rndQuPop

  let item = rq.tab[key]
  rq.tab.del(key)

  rq.tab[item.prv].nxt = item.nxt
  rq.tab[item.nxt].prv = item.prv
  ok(item)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc `$`*[K,V](data: RndQuDataRef[K,V]): string =
  ## Pretty print data container item.
  ##
  ## :CAVEAT:
  ##   This function needs working definitions for the `key` and `value` items:
  ##   ::
  ##    proc `$`*[K](key: K): string {.gcsafe,raises:[Defect,CatchableError].}
  ##    proc `$`*[V](value: V): string {.gcsafe,raises:[Defect,CatchableError].}
  ##
  if data.isNil:
    "nil"
  else:
    "(" & $data.value & ", link[" & $data.prv & "," & $data.nxt & "])"

proc rndQuVerify*[K,V](rq: RndQuRef[K,V]):
                Result[void,(K,RndQuDataRef[K,V],rndQuInfo)]
                 {.gcsafe,raises: [Defect,KeyError].} =
  ## ...
  let tabLen = rq.tab.len
  if tabLen == 0:
    return

  # Ckeck first and last items
  if rq.tab[rq.first].prv != rq.tab[rq.first].nxt:
    return err((rq.first, rq.tab[rq.first], rndQuVfyFirstInconsistent))

  if rq.tab[rq.last].prv != rq.tab[rq.last].nxt:
    return err((rq.last, rq.tab[rq.last], rndQuVfyLastInconsistent))

  # Forward walk item list
  var key = rq.first
  for _ in 1 .. tabLen:
    if not rq.tab.hasKey(key):
      return err((key, nil, rndQuVfyNoSuchTabItem))
    if not rq.tab.hasKey(rq.tab[key].nxt):
      return err((rq.tab[key].nxt, rq.tab[key], rndQuVfyNoNxtTabItem))
    if key != rq.last and key != rq.tab[rq.tab[key].nxt].prv:
      return err((key, rq.tab[rq.tab[key].nxt], rndQuVfyNxtPrvExpected))
    key = rq.tab[key].nxt
  if rq.tab[key].nxt != rq.last:
    return err((key, rq.tab[key], rndQuVfyLastExpected))

  # Backwards walk item list
  key = rq.last
  for _ in 1 .. tabLen:
    if not rq.tab.hasKey(key):
      return err((key, nil, rndQuVfyNoSuchTabItem))
    if not rq.tab.hasKey(rq.tab[key].prv):
      return err((rq.tab[key].prv, rq.tab[key], rndQuVfyNoPrvTabItem))
    if key != rq.first and key != rq.tab[rq.tab[key].prv].nxt:
      return err((key, rq.tab[rq.tab[key].prv], rndQuVfyPrvNxtExpected))
    key = rq.tab[key].prv
  if rq.tab[key].prv != rq.first:
    return err((key, rq.tab[key], rndQuVfyFirstExpected))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
