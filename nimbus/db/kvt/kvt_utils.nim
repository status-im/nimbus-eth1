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
  eth/common,
  results,
  ./kvt_desc/desc_backend,
  "."/[kvt_desc, kvt_layers]

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

  let data = db.layersGet(key).valueOr:
    return db.getBE key

  return ok(data)


proc hasKey*(
    db: KvtDbRef;                     # Database
    key: openArray[byte];             # Key of database record
      ): Result[bool,KvtError] =
  ## For the argument `key` return the associated value preferably from the
  ## top layer, or the database otherwise.
  ##
  if key.len == 0:
    return err(KeyInvalid)

  if db.layersHasKey @key:
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
