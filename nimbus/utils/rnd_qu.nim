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
  RndQuInfo* = enum ##\
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

  RndQuItemRef*[K,V] = ref object ##\
    ## Data value container as stored in the queue
    value*: V            ## Some value, can freely be modified
    prv, nxt: K          ## Queue links, read-only

  RndQuTab[K,V] =
    Table[K,RndQuItemRef[K,V]]

  RndQuRef*[K,V] = ref object of RootObj ##\
    ## Data queue descriptor
    tab: RndQuTab[K,V]   ## Data table
    first, last: K       ## Doubly linked item list queue

  RndQuResult*[K,V] = ##\
    ## Data value container or error code, typically used as value \
    ## returned from functions.
    Result[RndQuItemRef[K,V],void]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc isFirstItem[K,V](rq: RndQuRef[K,V]; item: RndQuItemRef[K,V]): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  if 0 < rq.tab.len and
     rq.tab[rq.first].nxt == item.prv: # terminal node has: nxt == prv
    return true

proc isLastItem[K,V](rq: RndQuRef[K,V]; item: RndQuItemRef[K,V]): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  if 0 < rq.tab.len and
     rq.tab[rq.last].prv == item.nxt: # terminal node has: nxt == prv
    return true

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc newRndQu*[K,V](initSize = 10): RndQuRef[K,V] =
  ## Constructor for queue with data random access
  RndQuRef[K,V](
    tab: initTable[K,RndQuItemRef[K,V]](initSize.nextPowerOfTwo))

# ------------------------------------------------------------------------------
# Public functions, list operations
# ------------------------------------------------------------------------------

proc append*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Append new `key`. The function returns the data container item relative
  ## to the `key` argument unless the `key` exists already in the queue.
  ##
  ## All the items on the queue different from the returned data
  ## container item are called *previous* or *left hand* items.
  if rq.tab.hasKey(key):
    return err()

  # Append queue item
  let item = RndQuItemRef[K,V]()

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

template push*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V] =
  ## Same as `append()`
  rq.append(key)


proc prepend*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Prepend new `key`. The function returns the data container item relative
  ## to the `key` argument unless the `key` exists already in the queue.
  ##
  ## All the items on the queue different from the returned data
  ## container item are called *following* or *right hand* items.
  if rq.tab.hasKey(key):
    return err()

  # Prepend queue item
  let item = RndQuItemRef[K,V]()

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

template unshift*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V] =
  ## Same as `prepend()`
  rq.prepend(key)


proc shift*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Deletes the *first* queue item and returns the data container item
  ## deleted. For a non-empty queue this function is the same as
  ## `rq.firstKey.value.delele`.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## item returned and deleted is the most *left hand* item.
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


proc pop*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Deletes the *last* queue item and returns the data container item
  ## deleted. For a non-empty queue this function is the same as
  ## `rq.lastKey.value.delele`.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## item returned and deleted is the most *right hand* item.
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


proc delete*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete the item with key `key` from the queue and returns the data
  ## container item deleted (if any).
  if not rq.tab.hasKey(key):
    return err()

  if rq.first == key:
    return rq.shift
  if rq.last == key:
    return rq.pop

  let item = rq.tab[key]
  rq.tab.del(key)

  rq.tab[item.prv].nxt = item.nxt
  rq.tab[item.nxt].prv = item.prv
  ok(item)

# ------------------------------------------------------------------------------
# Public functions, fetch
# ------------------------------------------------------------------------------

proc eq*[K,V](rq: RndQuRef[K,V]; key: K): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the data container item stored with the argument `key` from
  ## the queue if there is any.
  if not rq.tab.hasKey(key):
    return err()
  ok(rq.tab[key])

proc eq*[K,V](rq: RndQuRef[K,V]; item: RndQuItemRef[K,V]): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key for the argument `item` (if any.)
  ##
  ## Note that this function comes with considerable overhead as only
  ## predecessor/successor is stored in the argument data container `item`.
  if not rq.tab.hasKey(item.prv):
    return err()
  if rq.isFirstItem(item):
    return ok(rq.first)
  if rq.isLastItem(item):
    return ok(rq.last)
  let key = rq.tab[item.prv].nxt
  if rq.tab[key] != item:
    return err()
  ok(key)

# ------------------------------------------------------------------------------
# Public functions, getter
# ------------------------------------------------------------------------------

proc len*[K,V](rq: RndQuRef[K,V]): int {.inline.} =
  ## Returns the number of items in the queue
  rq.tab.len

proc prv*[K,V](item: RndQuItemRef[K,V]): K {.inline.} =
  ## Getter
  item.prv

proc nxt*[K,V](item: RndQuItemRef[K,V]): K {.inline.} =
  ## Getter
  item.nxt

# ------------------------------------------------------------------------------
# Public traversal functions, fetch keys
# ------------------------------------------------------------------------------

proc firstKey*[K,V](rq: RndQuRef[K,V]): Result[K,void] =
  ## Retrieve first key from queue unless the list is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the most *left hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.first)

proc lastKey*[K,V](rq: RndQuRef[K,V]): Result[K,void] =
  ## Retrieve last key from queue unless the list is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the most *right hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.last)

proc nextKey*[K,V](rq: RndQuRef[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key following the argument `key` from queue if
  ## there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the next one to the *right*.
  if not rq.tab.hasKey(key) of rq.last == key:
    return err()
  rq.tab[key].nxt

proc prevKey*[K,V](rq: RndQuRef[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key preceeding the argument `key` from queue if
  ## there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the next one to the *left*.
  if not rq.tab.hasKey(key) of rq.first == key:
    return err()
  rq.tab[key].prv

# ------------------------------------------------------------------------------
# Public traversal functions, data container items
# ------------------------------------------------------------------------------

proc first*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V] =
  ## Retrieve first data container item unless the list is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## data container item returned is the most *left hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rw.tab[rq.first])

proc last*[K,V](rq: RndQuRef[K,V]): RndQuResult[K,V] =
  ## Retrieve last data container item unless the list is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## data container item returned is the most *right hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rw.tab[rq.last])

proc next*[K,V](rq: RndQuRef[K,V]; item: RndQuItemRef[K,V]): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the data container item following the argument `item` from the
  ## queue if there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## data container item returned is the next one to the *right*.
  if rq.isLastItem(item):
    return err()
  ok(rw.tab[item.nxt])

proc prev*[K,V](rq: RndQuRef[K,V]; item: RndQuItemRef[K,V]): RndQuResult[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the data container item preceding the argument `item` from the
  ## queue if there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## data container item returned is the next one to the *left*.
  if rq.isFirstItem(item):
    return err()
  ok(rw.tab[item.prv])

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator nextKeys*[K,V](rq: RndQuRef[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all keys in the queue starting with the
  ## `rq.firstKey.value` key (if any).
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## iterator processes *left* to *right*.
  if 0 < rq.tab.len:
    var key = rq.first
    while true:
      yield key
      if key == rq.last:
        break
      key = rq.tab[key].nxt

iterator nextPairs*[K,V](rq: RndQuRef[K,V]): (K,V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all (key,value) pairs in the queue starting with the
  ## `(rq.firstKey.value,rq.first.value)` key/item pair (if any).
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## iterator processes *left* to *right*.
  if 0 < rq.tab.len:
    var key = rq.first
    while true:
      let item = rq.tab[key]
      yield (key,item.value)
      if key == rq.last:
        break
      key = item.nxt


iterator prevKeys*[K,V](rq: RndQuRef[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all keys in the queue starting with the
  ## `rq.lastKey.value` key (if any).
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## iterator processes *right* to *left*.
  if 0 < rq.tab.len:
    var key = rq.last
    while true:
      yield key
      if key == rq.first:
        break
      key = rq.tab[key].prv

iterator prevPairs*[K,V](rq: RndQuRef[K,V]): (K,V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all (key,value) pairs in the queue starting with the
  ## `(rq.lastKey.value,rq.last.value)` key/item pair (if any).
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## iterator processes *right* to *left*.
  if 0 < rq.tab.len:
    var key = rq.last
    while true:
      let item = rq.tab[key]
      yield (key,item.value)
      if key == rq.first:
        break
      key = item.prv

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc `$`*[K,V](item: RndQuItemRef[K,V]): string =
  ## Pretty print data container item.
  ##
  ## :CAVEAT:
  ##   This function needs working definitions for the `key` and `value` items:
  ##   ::
  ##    proc `$`*[K](key: K): string {.gcsafe,raises:[Defect,CatchableError].}
  ##    proc `$`*[V](value: V): string {.gcsafe,raises:[Defect,CatchableError].}
  ##
  if item.isNil:
    "nil"
  else:
    "(" & $item.value & ", link[" & $item.prv & "," & $item.nxt & "])"

proc verify*[K,V](rq: RndQuRef[K,V]):
           Result[void,(K,RndQuItemRef[K,V],RndQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Check for consistency. Returns and error unless the argument
  ## queue `rq` is consistent.
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
