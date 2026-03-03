# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  results,
  "."/[kvt_desc, kvt_layers]

export results

# ------------------------------------------------------------------------------
# Public functions, converters
# ------------------------------------------------------------------------------

proc getBe*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[seq[byte],KvtError] =
  ## For the argument `key` return the associated value from the backend
  ## database if available.
  ##
  db.getKvpFn key

proc getBeLen*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[int,KvtError] =
  ## For the argument `key` return the associated value from the backend
  ## database if available.
  ##
  db.lenKvpFn key

proc multiGetBe*(
    db: KvtDbRef,
    keys: openArray[seq[byte]],
    values: var openArray[Opt[seq[byte]]],
    sortedInput = false,
      ): Result[void, KvtError] =
  db.multiGetKvpFn(keys, values, sortedInput)

# ------------

proc delBe*(
    db: KvtDbRef,
    key: openArray[byte]
      ): Result[void, KvtError] =
  db.delKvpFn(key)

proc delRangeBe*(
    db: KvtDbRef,
    startKey, endKey: openArray[byte],
    compactRange = false
      ): Result[void, KvtError] =
  db.delRangeKvpFn(startKey, endKey, compactRange)

# ------------

proc put*(
    db: KvtTxRef;                     # Database
    key: openArray[byte];             # Key of database record to store
    data: openArray[byte];            # Value of database record to store
      ): Result[void,KvtError] =
  ## For the argument `key` associated the argument `data` as value (which
  ## will be marked in the top layer cache.)
  if key.len == 0:
    return err(KeyInvalid)
  if data.len == 0:
    return err(DataInvalid)

  db.layersPut(key, data)
  ok()


proc del*(
    db: KvtTxRef;                     # Database
    key: openArray[byte];             # Key of database record to delete
      ): Result[void,KvtError] =
  ## For the argument `key` delete the associated value (which will be marked
  ## in the top layer cache.)
  if key.len == 0:
    return err(KeyInvalid)

  db.layersPut(key, EmptyBlob)
  ok()

# ------------

proc get*(
    db: KvtTxRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[seq[byte],KvtError] =
  ## For the argument `key` return the associated value preferably from the
  ## top layer, or the database otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  var data = db.layersGet(key).valueOr:
    return db.db.getBe key

  return ok(move(data))

proc len*(
    db: KvtTxRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[int,KvtError] =
  ## For the argument `key` return the length of the associated value,
  ## preferably from the top layer, or the database otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  let len = db.layersLen(key).valueOr:
    return db.db.getBeLen key
  ok(len)

proc multiGet*(
    db: KvtTxRef,
    keys: openArray[seq[byte]],
    values: var openArray[Opt[seq[byte]]],
    sortedInput = false,
      ): Result[void, KvtError] =

  var
    remainingKeys: seq[seq[byte]] # keys to fetch from the db backend
    keyIndexes: seq[int] # record the indexes from the original keys list

  # First fetch each key from the in memory layers
  for i, k in keys:
    let value = db.layersGet(k)
    if value.isSome():
      values[i] = value
    else:
      remainingKeys.add(k)
      keyIndexes.add(i)

  # Fetch the remaining keys from the db backend
  if remainingKeys.len() > 0:
    var remainingValues = newSeq[Opt[seq[byte]]](remainingKeys.len())
    ?db.db.multiGetBe(remainingKeys, remainingValues)

    for i, v in remainingValues:
      let index = keyIndexes[i]
      values[index] = v

  ok()

proc hasKeyRc*(
    db: KvtTxRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[bool,KvtError] =
  ## For the argument `key` return `true` if `get()` returned a value on
  ## that argument, `false` if it returned `GetNotFound`, and an error
  ## otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  if db.layersHasKey key:
    return ok(true)

  let rc = db.db.getBe key
  if rc.isOk:
    return ok(true)
  if rc.error == GetNotFound:
    return ok(false)
  err(rc.error)

proc hasKey*(
    db: KvtTxRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): bool =
  ## Simplified version of `hasKeyRc` where `false` is returned instead of
  ## an error.
  db.hasKeyRc(key).valueOr: false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
