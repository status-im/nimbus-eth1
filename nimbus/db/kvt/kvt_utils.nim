# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  std/tables,
  eth/common,
  results,
  ./kvt_desc/desc_backend,
  "."/[kvt_desc, kvt_layers]

# ------------------------------------------------------------------------------
# Public functions, converters
# ------------------------------------------------------------------------------

proc getUbe*(
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

proc getUbeLen*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[int,KvtError] =
  ## For the argument `key` return the associated value from the backend
  ## database if available.
  ##
  let be = db.backend
  if not be.isNil:
    return be.lenKvpFn key
  err(GetNotFound)

proc getBe*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[Blob,KvtError] =
  ## Get the vertex from the (filtered) backened if available.
  if not db.balancer.isNil:
    db.balancer.sTab.withValue(@key, w):
      if w[].len == 0:
        return err(GetNotFound)
      return ok(w[])
  db.getUbe key

proc getBeLen*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[int,KvtError] =
  ## Get the vertex from the (filtered) backened if available.
  if not db.balancer.isNil:
    db.balancer.sTab.withValue(@key, w):
      if w[].len == 0:
        return err(GetNotFound)
      return ok(w[].len)
  db.getUbeLen key

# ------------

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

  db.layersPut(key, data)
  ok()


proc del*(
    db: KvtDbRef;                     # Database
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
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[Blob,KvtError] =
  ## For the argument `key` return the associated value preferably from the
  ## top layer, or the database otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  var data = db.layersGet(key).valueOr:
    return db.getBe key

  return ok(move(data))

proc len*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[int,KvtError] =
  ## For the argument `key` return the length of the associated value,
  ## preferably from the top layer, or the database otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  let len = db.layersLen(key).valueOr:
    return db.getBeLen key
  ok(len)

proc hasKeyRc*(
    db: KvtDbRef;                     # Database
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

  let rc = db.getBe key
  if rc.isOk:
    return ok(true)
  if rc.error == GetNotFound:
    return ok(false)
  err(rc.error)

proc hasKey*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): bool =
  ## Simplified version of `hasKeyRc` where `false` is returned instead of
  ## an error.
  db.hasKeyRc(key).valueOr: false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
