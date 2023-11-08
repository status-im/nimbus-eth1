# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB store data iterator
## ============================
##
{.push raises: [].}

import
  std/sequtils,
  eth/common,
  stew/endians2,
  rocksdb,
  ../init_common,
  ./rdb_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func keyPfx(kData: cstring, kLen: csize_t): int =
  if not kData.isNil and kLen == 1 + sizeof(uint64):
    kData.toOpenArrayByte(0,0)[0].int
  else:
    -1

func keyXid(kData: cstring, kLen: csize_t): uint64 =
  if not kData.isNil and kLen == 1 + sizeof(uint64):
    return uint64.fromBytesBE kData.toOpenArrayByte(1,int(kLen)-1).toSeq

func valBlob(vData: cstring, vLen: csize_t): Blob =
  if not vData.isNil and 0 < vLen:
    return vData.toOpenArrayByte(0,int(vLen)-1).toSeq


# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc pp(kd: cstring, kl: csize_t): string =
  if kd.isNil: "n/a" else: $kd.keyXid(kl)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walk*(
    rdb: RdbInst;
      ): tuple[n: int, pfx: StorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  let rit = rdb.store.db.rocksdb_create_iterator(rdb.store.readOptions)
  defer: rit.rocksdb_iter_destroy()

  rit.rocksdb_iter_seek_to_first()
  var count = 0

  while rit.rocksdb_iter_valid() != 0:
    var kLen: csize_t
    let kData = rit.rocksdb_iter_key(addr kLen)

    let pfx = kData.keyPfx(kLen)
    if 0 <= pfx:
      if high(StorageType).ord < pfx:
        break

      let xid = kData.keyXid(kLen)
      if 0 < xid:
        var vLen: csize_t
        let vData = rit.rocksdb_iter_value(addr vLen)

        let val = vData.valBlob(vLen)
        if 0 < val.len:
          yield (count, pfx.StorageType, xid, val)

    # Update Iterator (might overwrite kData/vdata)
    rit.rocksdb_iter_next()
    count.inc
    # End while


iterator walk*(
    rdb: RdbInst;
    pfx: StorageType;
      ): tuple[n: int, xid: uint64, data: Blob] =
  ## Walk over key-value pairs of the table referted to by the argument `pfx`
  ## whic must be different from `Oops` and `AdmPfx`.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  ##
  block walkBody:
    if pfx in {Oops, AdmPfx}:
      # Unsupported
      break walkBody

    let rit = rdb.store.db.rocksdb_create_iterator(rdb.store.readOptions)
    defer: rit.rocksdb_iter_destroy()

    var
      count = 0
      kLen: csize_t
      kData: cstring

    # Seek for `VertexID(1)` and subsequent entries if that fails. There should
    # always be a `VertexID(1)` entry unless the sub-table is empty. There is
    # no such control for the filter table in which case there is a blind guess
    # (in case `rocksdb_iter_seek()` does not search `ge` for some reason.)
    let keyOne = 1u64.toRdbKey pfx

    # It is not clear what happens when the `key` does not exist. The guess
    # is that the interation will proceed at the next key position.
    #
    # Comment from GO port at
    #    //github.com/DanielMorsing/rocksdb/blob/master/iterator.go:
    #
    # Seek moves the iterator the position of the key given or, if the key
    # doesn't exist, the next key that does exist in the database. If the key
    # doesn't exist, and there is no next key, the Iterator becomes invalid.
    #
    kData = cast[cstring](unsafeAddr keyOne[0])
    kLen = sizeof(keyOne).csize_t
    rit.rocksdb_iter_seek(kData, kLen)
    if rit.rocksdb_iter_valid() == 0:
      break walkBody

    # Fetch sub-table data
    while true:
      kData = rit.rocksdb_iter_key(addr kLen)
      if pfx.ord != kData.keyPfx kLen:
        break walkBody # done

      let xid = kData.keyXid(kLen)
      if 0 < xid:
        # Fetch value data
        var vLen: csize_t
        let vData = rit.rocksdb_iter_value(addr vLen)

        let val = vData.valBlob(vLen)
        if 0 < val.len:
          yield (count, xid, val)

      # Update Iterator
      rit.rocksdb_iter_next()
      if rit.rocksdb_iter_valid() == 0:
        break walkBody

      count.inc
      # End while

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
