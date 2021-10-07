# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Key Queue, Debuugig support
## ===========================
##

import
  std/tables,
  ../keequ,
  stew/results

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc `$`*[K,V](item: KeeQuItem[K,V]): string =
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
    "(" & $item.value & ", link[" & $item.prv & "," & $item.kNxt & "])"

proc verify*[K,V](rq: var KeeQu[K,V]): Result[void,(K,V,KeeQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Check for consistency. Returns an error unless the argument
  ## queue `rq` is consistent.
  let tabLen = rq.tab.len
  if tabLen == 0:
    return ok()

  # Ckeck first and last items
  if rq.tab[rq.kFirst].kPrv != rq.tab[rq.kFirst].kNxt:
    return err((rq.kFirst, rq.tab[rq.kFirst].data, keeQuVfyFirstInconsistent))

  if rq.tab[rq.kLast].kPrv != rq.tab[rq.kLast].kNxt:
    return err((rq.kLast, rq.tab[rq.kLast].data, keeQuVfyLastInconsistent))

  # Just a return value
  var any: V

  # Forward walk item list
  var key = rq.kFirst
  for _ in 1 .. tabLen:
    if not rq.tab.hasKey(key):
      return err((key, any, keeQuVfyNoSuchTabItem))
    if not rq.tab.hasKey(rq.tab[key].kNxt):
      return err((rq.tab[key].kNxt, rq.tab[key].data, keeQuVfyNoNxtTabItem))
    if key != rq.kLast and key != rq.tab[rq.tab[key].kNxt].kPrv:
      return err((key, rq.tab[rq.tab[key].kNxt].data, keeQuVfyNxtPrvExpected))
    key = rq.tab[key].kNxt
  if rq.tab[key].kNxt != rq.kLast:
    return err((key, rq.tab[key].data, keeQuVfyLastExpected))

  # Backwards walk item list
  key = rq.kLast
  for _ in 1 .. tabLen:
    if not rq.tab.hasKey(key):
      return err((key, any, keeQuVfyNoSuchTabItem))
    if not rq.tab.hasKey(rq.tab[key].kPrv):
      return err((rq.tab[key].kPrv, rq.tab[key].data, keeQuVfyNoPrvTabItem))
    if key != rq.kFirst and key != rq.tab[rq.tab[key].kPrv].kNxt:
      return err((key, rq.tab[rq.tab[key].kPrv].data, keeQuVfyPrvNxtExpected))
    key = rq.tab[key].kPrv
  if rq.tab[key].kPrv != rq.kFirst:
    return err((key, rq.tab[key].data, keeQuVfyFirstExpected))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
