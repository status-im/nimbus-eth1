# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Persistent kvt that ideally bypasses the `FC` logic. This can be used as a
## cache where in-memory storade would be much of a burden (e.g. all `mainnet`
## headers.)
##
## Currently, it is not always possible to store. But fortunately (for the
## syncer application) it works for some time at the beginning when the `FC`
## module is initialised and no block operation has been performed, yet.

{.push raises: [].}

import
  pkg/results,
  ../../../common,
  ../../../db/core_db,
  ./chain_desc

proc fcKvtAvailable*(c: ForkedChainRef): bool =
  ## Returns `true` if `kvt` data can be saved persistently.
  c.db.txFrameLevel() == 0

proc fcKvtPersistent*(c: ForkedChainRef): bool =
  ## Save cached `kvt` data if possible. This function has the side effect
  ## that it saves all cached db data including `Aristo` data (although there
  ## should not be any.)
  ##
  if c.fcKvtAvailable():
    c.db.persistent(c.db.getSavedStateBlockNumber()).isOkOr:
      raiseAssert "fcKvtPersistent: persistent() failed: " & $$error
    return true

proc fcKvtHasKey*(c: ForkedChainRef, key: openArray[byte]): bool =
  ## Check whether the argument `key` exists on the `kvt` table (i.e. `get()`
  ## would succeed.)
  ##
  c.db.ctx.getKvt().hasKey(key)

proc fcKvtGet*(c: ForkedChainRef, key: openArray[byte]): Opt[seq[byte]] =
  ## Fetch data entry from `kvt` table.
  ##
  var w = c.db.ctx.getKvt().get(key).valueOr:
    return err()
  ok(move w)

proc fcKvtPut*(c: ForkedChainRef, key, data: openArray[byte]): bool =
  ## Cache data on the `kvt` table marked for saving persistently. If the `kvt`
  ## table is unavailable, this function does nothing and returns `false`.
  ##
  if c.fcKvtAvailable():
    c.db.ctx.getKvt().put(key, data).isOkOr:
      raiseAssert "fcKvtPut: put() failed: " & $$error
    return true

proc fcKvtDel*(c: ForkedChainRef, key: openArray[byte]): bool =
  ## Cache key for deletion on the  `kvt` table.  If the `kvt` table is
  ## unavailable, this function does nothing and returns `false`.
  ##
  if c.fcKvtAvailable():
    c.db.ctx.getKvt().del(key).isOkOr:
      raiseAssert "fcKvtDel: del() failed: " & $$error
    return true
    
# End
