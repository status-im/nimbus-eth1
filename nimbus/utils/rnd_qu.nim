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
## For consistency with  other data types in Nim the queue has value
## semantics, this means that `=` performs a deep copy of the allocated queue
## which is refered to the deep copy semantics of underlying table driver.
##
## This module supports *RLP* serialisation. Note that the underlying RLP
## driver does not support negative integers which cuses problems when
## reading back. So these values should neither appear in any of the `K`
## (for key) or `V` (for value) data types (best to avoid `int` altogether
## if serialisation is needed.)
##
import
  std/[math, tables],
  eth/rlp,
  stew/results

export
  results

type
  RndQueueInfo* = enum ##\
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

  RndQueueItem[K,V] = object ##\
    ## Data value container as stored in the queue.
    ## There is a special requirements for `RndQueueItem` terminal nodes:
    ## *prv == nxt* so that there is no dangling link. On the flip side,
    ## this requires some extra consideration when deleting the second node
    ## relative to either end.
    data: V       ## Some data value, can freely be modified.
    prv, nxt: K   ## Queue links, read-only.

  RndQueuePair*[K,V] = object ##\
    ## Key-value pair, typically used as return code.
    key*: K
    data*: V

  RndQueueTab[K,V] =
    Table[K,RndQueueItem[K,V]]

  RndQueue*[K,V] = object of RootObj ##\
    ## Data queue descriptor
    tab: RndQueueTab[K,V] ## Data table
    first, last: K        ## Doubly linked item list queue

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc shiftImpl[K,V](rq: var RndQueue[K,V])
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: rq.tab.len != 0

  # Unqueue first item
  let item = rq.tab[rq.first] # yes, crashes if `rq.tab.len == 0`
  rq.tab.del(rq.first)

  if rq.tab.len == 0:
    rq.first.reset
    rq.last.reset
  else:
    rq.first = item.nxt
    if rq.tab.len == 1:
      rq.tab[rq.first].nxt = rq.first           # single node points to itself
    rq.tab[rq.first].prv = rq.tab[rq.first].nxt # terminal node has: nxt == prv


proc popImpl[K,V](rq: var RndQueue[K,V])
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: rq.tab.len != 0

  # Pop last item
  let item = rq.tab[rq.last] # yes, crashes if `rq.tab.len == 0`
  rq.tab.del(rq.last)

  if rq.tab.len == 0:
    rq.first.reset
    rq.last.reset
  else:
    rq.last = item.prv
    if rq.tab.len == 1:
      rq.tab[rq.last].prv = rq.last           # single node points to itself
    rq.tab[rq.last].nxt = rq.tab[rq.last].prv # terminal node has: nxt == prv


proc deleteImpl[K,V](rq: var RndQueue[K,V]; key: K)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: rq.tab.hesKey(key)

  if rq.first == key:
    rq.shiftImpl

  elif rq.last == key:
    rq.popImpl

  else:
    let item = rq.tab[key] # yes, crashes if `not rq.tab.hasKey(key)`
    rq.tab.del(key)

    # now: 2 < rq.tab.len (otherwise rq.first == key or rq.last == key)
    if rq.tab[rq.first].nxt == key:
      # item was the second one
      rq.tab[rq.first].prv = item.nxt
    if rq.tab[rq.last].prv == key:
      # item was one before last
      rq.tab[rq.last].nxt = item.prv

    rq.tab[item.prv].nxt = item.nxt
    rq.tab[item.nxt].prv = item.prv


proc appendImpl[K,V](rq: var RndQueue[K,V]; key: K; val: V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: not rq.tab.hasKey(key)

  # Append queue item
  var item = RndQueueItem[K,V](data: val)

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

  rq.tab[key] = item # yes, makes `verify()` fail if `rq.tab.hasKey(key)`


proc prependImpl[K,V](rq: var RndQueue[K,V]; key: K; val: V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Expects: not rq.tab.hasKey(key)

  # Prepend queue item
  var item = RndQueueItem[K,V](data: val)

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

  rq.tab[key] = item # yes, makes `verify()` fail if `rq.tab.hasKey(key)`

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*[K,V](rq: var RndQueue[K,V]; initSize = 10) =
  ## Optional initaliser for queue setting inital size for underlying
  ## table object.
  rq.tab = initTable[K,RndQueueItem[K,V]](initSize.nextPowerOfTwo)

# ------------------------------------------------------------------------------
# Public functions, list operations
# ------------------------------------------------------------------------------

proc append*[K,V](rq: var RndQueue[K,V]; key: K; val: V): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Append new `key`. The function will succeed returning `true` unless the
  ## `key` argument exists in the queue,  already.
  ##
  ## All the items on the queue different from the one just added are
  ## called *previous* or *left hand* items.
  if not rq.tab.hasKey(key):
    rq.appendImpl(key, val)
    return true

template push*[K,V](rq: var RndQueue[K,V]; key: K; val: V): bool =
  ## Same as `append()`
  rq.append(key, val)


proc replace*[K,V](rq: var RndQueue[K,V]; key: K; val: V): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Replace value for entry associated with the key argument `key`. Returns
  ## `true` on success, and `false` otherwise.
  if rq.tab.hasKey(key):
    rq.tab[key].data = val
    return true

proc `[]=`*[K,V](rq: var RndQueue[K,V]; key: K; val: V)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## This function provides a combined append/replace action with table
  ## semantics:
  ## * If the argument `key` is not in the queue yet, append the `(key,val)`
  ##   pair as in `rq.append(key,val)`
  ## * Otherwise replace the value entry of the queue item by the argument
  ##   `val` as in `rq.replace(key,val)`
  if rq.tab.hasKey(key):
    rq.tab[key].data = val
  else:
    rq.appendImpl(key, val)


proc prepend*[K,V](rq: var RndQueue[K,V]; key: K; val: V): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Prepend new `key`. The function will succeed returning `true` unless the
  ## `key` argument exists in the queue, already.
  ##
  ## All the items on the queue different from the item just added are
  ## called *following* or *right hand* items.
  if not rq.tab.hasKey(key):
    rq.prependImpl(key, val)
    return true

template unshift*[K,V](rq: var RndQueue[K,V]; key: K; val: V): bool =
  ## Same as `prepend()`
  rq.prepend(key,val)


proc shift*[K,V](rq: var RndQueue[K,V]): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Deletes the *first* queue item and returns the key-value item pair just
  ## deleted. For a non-empty queue this function is the same as
  ## `rq.firstKey.value.delele`.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## item returned and deleted is the most *left hand* item.
  if 0 < rq.tab.len:
    let kvp = RndQueuePair[K,V](
      key: rq.first,
      val: rq.tab[rq.first].data)
    rq.shiftImpl
    return ok(RndQueuePair[K,V](kvp))
  err()

proc shiftKey*[K,V](rq: var RndQueue[K,V]):
             Result[K,void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `shift()` but with different return value.
  if 0 < rq.tab.len:
    let key = rq.first
    rq.shiftImpl
    return ok(key)
  err()

proc shiftValue*[K,V](rq: var RndQueue[K,V]):
               Result[V,void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `shift()` but with different return value.
  if 0 < rq.tab.len:
    let val = rq.tab[rq.first].data
    rq.shiftImpl
    return ok(val)
  err()


proc pop*[K,V](rq: var RndQueue[K,V]): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Deletes the *last* queue item and returns the  key-value item pair just
  ## deleted. For a non-empty queue this function is the same as
  ## `rq.lastKey.value.delele`.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## item returned and deleted is the most *right hand* item.
  if 0 < rq.tab.len:
    let kvp = RndQueuePair[K,V](
      key: rq.last,
      val: rq.tab[rq.last].data)
    rq.popImpl
    return ok(RndQueuePair[K,V](key,val))
  err()

proc popKey*[K,V](rq: var RndQueue[K,V]):
           Result[K,void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `pop()` but with different return value.
  if 0 < rq.tab.len:
    let key = rq.last
    rq.popImpl
    return ok(key)
  err()

proc popValue*[K,V](rq: var RndQueue[K,V]):
             Result[V,void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `pop()` but with different return value.
  if 0 < rq.tab.len:
    let val = rq.tab[rq.last].data
    rq.popImpl
    return ok(val)
  err()


proc delete*[K,V](rq: var RndQueue[K,V]; key: K):
           Result[RndQueuePair[K,V],void] {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete the item with key `key` from the queue and returns the key-value
  ## item pair just deleted (if any).
  if rq.tab.hasKey(key):
    let kvp = RndQueuePair[K,V](
      key: key,
      data: rq.tab[key].data)
    rq.deleteImpl(key)
    return ok(kvp)
  err()

proc del*[K,V](rq: var RndQueue[K,V]; key: K)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `delete()` but without return code.
  if rq.tab.hasKey(key):
    rq.deleteImpl(key)

# ------------------------------------------------------------------------------
# Public functions, fetch
# ------------------------------------------------------------------------------

proc hasKey*[K,V](rq: var RndQueue[K,V]; key: K): bool =
  ## Check whether the argument `key` has been queued, already
  rq.tab.hasKey(key)


proc eq*[K,V](rq: var RndQueue[K,V]; key: K): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the value data stored with the argument `key` from
  ## the queue if there is any.
  if not rq.tab.hasKey(key):
    return err()
  ok(rq.tab[key].data)

proc `[]`*[K,V](rq: var RndQueue[K,V]; key: K): V
    {.gcsafe,raises: [Defect,KeyError].} =
  ## This function provides a simplified version of the `eq()` function with
  ## table semantics. Note that this finction throws a `KeyError` exception
  ## unless the argument `key` exists in the queue.
  rq.tab[key].data

# ------------------------------------------------------------------------------
# Public traversal functions, fetch keys
# ------------------------------------------------------------------------------

proc firstKey*[K,V](rq: var RndQueue[K,V]): Result[K,void] =
  ## Retrieve first key from the queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the most *left hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.first)

proc secondKey*[K,V](rq: var RndQueue[K,V]): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key next after the first key from queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the one ti the right of the most *left hand* one.
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.first].nxt)

proc beforeLastKey*[K,V](rq: var RndQueue[K,V]): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key just before the last one from queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the one to the left of the most *right hand* one.
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.last].prv)

proc lastKey*[K,V](rq: var RndQueue[K,V]): Result[K,void] =
  ## Retrieve last key from queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the most *right hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.last)

proc nextKey*[K,V](rq: var RndQueue[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key following the argument `key` from queue if
  ## there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the next one to the *right*.
  if not rq.tab.hasKey(key) or rq.last == key:
    return err()
  ok(rq.tab[key].nxt)

proc prevKey*[K,V](rq: var RndQueue[K,V]; key: K): Result[K,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the key preceeding the argument `key` from queue if
  ## there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## key returned is the next one to the *left*.
  if not rq.tab.hasKey(key) or rq.first == key:
    return err()
  ok(rq.tab[key].prv)

# ------------------------------------------------------------------------------
# Public traversal functions, fetch key/value pairs
# ------------------------------------------------------------------------------

proc first*[K,V](rq: var RndQueue[K,V]): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `firstKey()` but with key-value item pair return value.
  if rq.tab.len == 0:
    return err()
  let key = rq.first
  ok(RndQueuePair[K,V](key: key, data: rq.tab[key].data))

proc second*[K,V](rq: var RndQueue[K,V]): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `secondKey()` but with key-value item pair return value.
  if rq.tab.len < 2:
    return err()
  let key = rq.tab[rq.first].nxt
  ok(RndQueuePair[K,V](key: key, data: rq.tab[key].data))

proc beforeLast*[K,V](rq: var RndQueue[K,V]): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `beforeLastKey()` but with key-value item pair return value.
  if rq.tab.len < 2:
    return err()
  let key = rq.tab[rq.last].prv
  ok(RndQueuePair[K,V](key: key, data: rq.tab[key].data))

proc last*[K,V](rq: var RndQueue[K,V]): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `lastKey()` but with key-value item pair return value.
  if rq.tab.len == 0:
    return err()
  let key = rq.last
  ok(RndQueuePair[K,V](key: key, data: rq.tab[key].data))

proc next*[K,V](rq: var RndQueue[K,V]; key: K): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `nextKey()` but with key-value item pair return value.
  if not rq.tab.hasKey(key) or rq.last == key:
    return err()
  let key = rq.tab[key].nxt
  ok(RndQueuePair[K,V](key: key, data: rq.tab[key].data))

proc prev*[K,V](rq: var RndQueue[K,V]; key: K): Result[RndQueuePair[K,V],void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `prevKey()` but with key-value item pair return value.
  if not rq.tab.hasKey(key) or rq.first == key:
    return err()
  let key = rq.tab[key].prv
  ok(RndQueuePair[K,V](key: key, data: rq.tab[key].data))

# ------------------------------------------------------------------------------
# Public traversal functions, data container items
# ------------------------------------------------------------------------------

proc firstValue*[K,V](rq: var RndQueue[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve first value item from the queue unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the most *left hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.tab[rq.first])

proc secondValue*[K,V](rq: var RndQueue[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the value item next to the first one from the queue unless it
  ## is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the one to the right of the most *left hand* one.
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.tab[rq.first].nxt])

proc beforeLastValue*[K,V](rq: var RndQueue[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the value item just before the last item from the queue
  ## unless it is empty.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the one to the left of the most *right hand* one.
  if rq.tab.len < 2:
    return err()
  ok(rq.tab[rq.tab[rq.last].prv])

proc lastValue*[K,V](rq: var RndQueue[K,V]): Result[V,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the last value item from the queue if there is any.
  ##
  ## Using the notation introduced with `rq.append` and `rq.prepend`, the
  ## value item returned is the most *right hand* one.
  if rq.tab.len == 0:
    return err()
  ok(rq.tab[rq.last])

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

proc `==`*[K,V](a, b: var RndQueue[K,V]): bool
    {.gcsafe, raises: [Defect,KeyError].} =
  ## Returns `true` if both argument queues contain the same data. Note that
  ## this is a slow operation as all items need to be compared.
  if a.tab.len == b.tab.len and a.first == b.first and a.last == b.last:
    for (k,av) in a.tab.pairs:
      if not b.tab.hasKey(k):
        return false
      let bv = b.tab[k]
      # bv.data might be a reference, so dive into it explicitely.
      if av.prv != bv.prv or av.nxt != bv.nxt or bv.data != av.data:
        return false
    return true

proc len*[K,V](rq: var RndQueue[K,V]): int {.inline.} =
  ## Returns the number of items in the queue
  rq.tab.len

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator nextKeys*[K,V](rq: var RndQueue[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all keys in the queue starting with the
  ## `rq.firstKey.value` key (if any). Using the notation introduced with
  ## `rq.append` and `rq.prepend`, the iterator processes *left* to *right*.
  ##
  ## Note: When running in a loop it is ok to delete the current item and the
  ## all items already visited. Items not visited yet must not be deleted.
  if 0 < rq.tab.len:
    var
      key = rq.first
      loopOK = true
    while loopOK:
      let yKey = key
      loopOK = key != rq.last
      key = rq.tab[key].nxt
      yield yKey

iterator nextValues*[K,V](rq: var RndQueue[K,V]): V
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all values in the queue starting with the
  ## `rq.first.value.value` item value (if any). Using the notation introduced
  ## with `rq.append` and `rq.prepend`, the iterator processes *left* to
  ## *right*.
  ##
  ## Note: When running in a loop it is ok to delete the current item and the
  ## all items already visited. Items not visited yet must not be deleted.
  if 0 < rq.tab.len:
    var
      key = rq.first
      loopOK = true
    while loopOK:
      let item = rq.tab[key]
      loopOK = key != rq.last
      key = item.nxt
      yield item.data

iterator nextPairs*[K,V](rq: var RndQueue[K,V]): RndQueuePair[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Iterate over all (key,value) pairs in the queue starting with the
  ## `(rq.firstKey.value,rq.first.value.value)` key/item pair (if any). Using
  ## the notation introduced with `rq.append` and `rq.prepend`, the iterator
  ## processes *left* to *right*.
  ##
  ## Note: When running in a loop it is ok to delete the current item and the
  ## all items already visited. Items not visited yet must not be deleted.
  if 0 < rq.tab.len:
    var
      key = rq.first
      loopOK = true
    while loopOK:
      let
        yKey = key
        item = rq.tab[key]
      loopOK = key != rq.last
      key = item.nxt
      yield RndQueuePair[K,V](key: yKey, data: item.data)

iterator prevKeys*[K,V](rq: var RndQueue[K,V]): K
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all keys in the queue starting with the
  ## `rq.lastKey.value` key (if any). Using the notation introduced with
  ## `rq.append` and `rq.prepend`, the iterator processes *right* to *left*.
  ##
  ## Note: When running in a loop it is ok to delete the current item and the
  ## all items already visited. Items not visited yet must not be deleted.
  if 0 < rq.tab.len:
    var
      key = rq.last
      loopOK = true
    while loopOK:
      let yKey = key
      loopOK = key != rq.first
      key = rq.tab[key].prv
      yield yKey

iterator prevValues*[K,V](rq: var RndQueue[K,V]): V
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all values in the queue starting with the
  ## `rq.last.value.value` item value (if any). Using the notation introduced
  ## with `rq.append` and `rq.prepend`, the iterator processes *right* to
  ## *left*.
  ##
  ## Note: When running in a loop it is ok to delete the current item and the
  ## all items already visited. Items not visited yet must not be deleted.
  if 0 < rq.tab.len:
    var
      key = rq.last
      loopOK = true
    while loopOK:
      let item = rq.tab[key]
      loopOK = key != rq.first
      key = item.prv
      yield item.data

iterator prevPairs*[K,V](rq: var RndQueue[K,V]): RndQueuePair[K,V]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reverse iterate over all (key,value) pairs in the queue starting with the
  ## `(rq.lastKey.value,rq.last.value.value)` key/item pair (if any). Using
  ## the notation introduced with `rq.append` and `rq.prepend`, the iterator
  ## processes *right* to *left*.
  ##
  ## Note: When running in a loop it is ok to delete the current item and the
  ## all items already visited. Items not visited yet must not be deleted.
  if 0 < rq.tab.len:
    var
      key = rq.last
      loopOK = true
    while loopOK:
      let
        yKey = key
        item = rq.tab[key]
      loopOK = key != rq.first
      key = item.prv
      yield RndQueuePair[K,V](key: yKey, data: item.data)

# ------------------------------------------------------------------------------
# Public functions, RLP support
# ------------------------------------------------------------------------------

proc append*[K,V](rw: var RlpWriter; data: RndQueue[K,V])
    {.inline, raises: [Defect,KeyError].} =
  ## Generic support for `rlp.encode(lru.data)` for serialising a queue.
  ##
  ## :CAVEAT:
  ##   The underlying *RLP* driver has a problem with negative integers
  ##   when reading. So it should neither appear in any of the `K` or `V`
  ##   data types.
  # store keys in increasing order
  rw.startList(data.tab.len)
  if 0 < data.tab.len:
    var key = data.first
    for _ in 1 .. data.tab.len:
      var item = data.tab[key]
      rw.append((key,item.data))
      key = item.nxt
    if data.tab[key].nxt != data.last:
      raiseAssert "Garbled queue next/prv references"

proc read*[K,V](rlp: var Rlp; Q: type RndQueue[K,V]): Q
    {.inline, raises: [Defect,RlpError,KeyError].} =
  ## Generic support for `rlp.decode(bytes)` for loading a queue
  ## from a serialised data stream.
  ##
  ## :CAVEAT:
  ##   The underlying *RLP* driver has a problem with negative integers
  ##   when reading. So it should neither appear in any of the `K` or `V`
  ##   data types.
  for w in rlp.items:
    let (key,value) = w.read((K,V))
    result[key] = value

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc `$`*[K,V](item: RndQueueItem[K,V]): string =
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

proc verify*[K,V](rq: var RndQueue[K,V]): Result[void,(K,V,RndQueueInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Check for consistency. Returns an error unless the argument
  ## queue `rq` is consistent.
  let tabLen = rq.tab.len
  if tabLen == 0:
    return ok()

  # Ckeck first and last items
  if rq.tab[rq.first].prv != rq.tab[rq.first].nxt:
    return err((rq.first, rq.tab[rq.first].data, rndQuVfyFirstInconsistent))

  if rq.tab[rq.last].prv != rq.tab[rq.last].nxt:
    return err((rq.last, rq.tab[rq.last].data, rndQuVfyLastInconsistent))

  # Just a return value
  var any: V

  # Forward walk item list
  var key = rq.first
  for _ in 1 .. tabLen:
    if not rq.tab.hasKey(key):
      return err((key, any, rndQuVfyNoSuchTabItem))
    if not rq.tab.hasKey(rq.tab[key].nxt):
      return err((rq.tab[key].nxt, rq.tab[key].data, rndQuVfyNoNxtTabItem))
    if key != rq.last and key != rq.tab[rq.tab[key].nxt].prv:
      return err((key, rq.tab[rq.tab[key].nxt].data, rndQuVfyNxtPrvExpected))
    key = rq.tab[key].nxt
  if rq.tab[key].nxt != rq.last:
    return err((key, rq.tab[key].data, rndQuVfyLastExpected))

  # Backwards walk item list
  key = rq.last
  for _ in 1 .. tabLen:
    if not rq.tab.hasKey(key):
      return err((key, any, rndQuVfyNoSuchTabItem))
    if not rq.tab.hasKey(rq.tab[key].prv):
      return err((rq.tab[key].prv, rq.tab[key].data, rndQuVfyNoPrvTabItem))
    if key != rq.first and key != rq.tab[rq.tab[key].prv].nxt:
      return err((key, rq.tab[rq.tab[key].prv].data, rndQuVfyPrvNxtExpected))
    key = rq.tab[key].prv
  if rq.tab[key].prv != rq.first:
    return err((key, rq.tab[key].data, rndQuVfyFirstExpected))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
