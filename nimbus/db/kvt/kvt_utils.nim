# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Common functions
## ==========================
##
{.push raises: [].}

import
  std/algorithm,
  eth/common,
  results,
  ./kvt_desc/desc_backend,
  ./kvt_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getBE(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[Blob,KvtError] =
  ## For the argument `key` return the associated value from the backend
  ## database if available.
  ##
  let be = db.backend
  if not be.isNil:
    return be.getKvpFn key
  err(GetNotFound)

# ------------------------------------------------------------------------------
# Public functions, converters
# ------------------------------------------------------------------------------

proc put*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record to store
    data: openArray[byte];            # Value of database record to store
      ): Result[void,KvtError] =
  ## For the argument `key` associated the argument `data` as value (which
  ## will be marked in the top layer cache.)
  if key.len == 0:
    return err(KeyInvalid)
  if data.len == 0:
    return err(DataInvalid)

  db.top.delta.sTab[@key] = @data
  ok()


proc del*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record to delete
      ): Result[void,KvtError] =
  ## For the argument `key` delete the associated value (which will be marked
  ## in the top layer cache.)
  if key.len == 0:
    return err(KeyInvalid)

  block haveKey:
    for w in db.stack.reversed:
      if w.delta.sTab.hasKey @key:
        break haveKey

    # Do this one last as it is the most expensive lookup
    let rc = db.getBE key
    if rc.isOk:
      break haveKey
    if rc.error != GetNotFound:
      return err(rc.error)

    db.top.delta.sTab.del @key        # No such key anywhere => delete now
    return ok()

  db.top.delta.sTab[@key] = EmptyBlob # Mark for deletion
  ok()

# ------------

proc get*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[Blob,KvtError] =
  ## For the argument `key` return the associated value preferably from the
  ## top layer, or the database otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  block:
    let data = db.top.delta.sTab.getOrVoid @key
    if data.isValid:
      return ok(data)

  block:
    for w in db.stack.reversed:
      let data = w.delta.sTab.getOrVoid @key
      if data.isValid:
        return ok(data)

  db.getBE key


proc hasKey*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[bool,KvtError] =
  ## For the argument `key` return the associated value preferably from the
  ## top layer, or the database otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  if db.top.delta.sTab.hasKey @key:
    return ok(true)

  for w in db.stack.reversed:
    if w.delta.sTab.haskey @key:
      return ok(true)

  let rc = db.getBE key
  if rc.isOk:
    return ok(true)
  if rc.error == GetNotFound:
    return ok(false)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
