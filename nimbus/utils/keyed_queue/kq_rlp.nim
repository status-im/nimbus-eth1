# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Keyed Queue, RLP Support
## ========================
##
## Note that the underlying RLP driver does not support negative integers
## which causes problems when reading back. So these values should neither
## appear in any of the `K` (for key) or `V` (for value) data types (best
## to avoid `int` altogether for `KeyedQueue` if serialisation is needed.)

import
  std/tables,
  eth/rlp,
  stew/keyed_queue

# ------------------------------------------------------------------------------
# Public functions, RLP support
# ------------------------------------------------------------------------------

proc append*[K,V](rw: var RlpWriter; kq: KeyedQueue[K,V])
    {.raises: [Defect,KeyError].} =
  ## Generic support for `rlp.encode(kq)` for serialising a queue.
  ##
  ## :CAVEAT:
  ##   The underlying *RLP* driver has a problem with negative integers
  ##   when reading. So it should neither appear in any of the `K` or `V`
  ##   data types.
  # store keys in increasing order
  var data = kq
  rw.startList(data.tab.len)
  if 0 < data.tab.len:
    var key = data.kFirst
    for _ in 1 .. data.tab.len:
      var item = data.tab[key]
      rw.append((key,item.data))
      key = item.kNxt
    if data.tab[key].kNxt != data.kLast:
      raiseAssert "Garbled queue next/prv references"

proc read*[K,V](rlp: var Rlp; Q: type KeyedQueue[K,V]): Q
    {.raises: [Defect,RlpError,KeyError].} =
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
# End
# ------------------------------------------------------------------------------
