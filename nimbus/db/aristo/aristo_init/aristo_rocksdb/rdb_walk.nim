# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  rocksdb,
  ../../aristo_desc,
  ../aristo_init_common,
  ./rdb_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func keyPfx(kData: cstring, kLen: csize_t): int =
  if not kData.isNil and kLen == 1 + sizeof(VertexID):
    kData.toOpenArrayByte(0,0)[0].int
  else:
    -1

func keyXid(kData: cstring, kLen: csize_t): uint64 =
  if not kData.isNil and kLen == 1 + sizeof(VertexID):
    return uint64.fromBytesBE kData.toOpenArrayByte(1,int(kLen)-1).toSeq

func to(xid: uint64; T: type Blob): T =
  xid.toBytesBE.toSeq

func valBlob(vData: cstring, vLen: csize_t): Blob =
  if not vData.isNil and 0 < vLen:
    return vData.toOpenArrayByte(0,int(vLen)-1).toSeq

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
  ## Walk over key-value pairs of the table referted to by the argument `pfx`.
  ##
  ## Non-decodable entries are stepped over while the counter `n` of the
  ## yield record is still incremented.
  let rit = rdb.store.db.rocksdb_create_iterator(rdb.store.readOptions)
  defer: rit.rocksdb_iter_destroy()

  rit.rocksdb_iter_seek_to_first()
  var
    count = 0
    kLen: csize_t
    kData: cstring

  block walkBody:
    # Skip over admin records (if any) and advance to the key sub-table
    if rit.rocksdb_iter_valid() == 0:
      break walkBody
    kData = rit.rocksdb_iter_key(addr kLen)

    case pfx:
    of Oops, IdgPfx:
      discard
    of VtxPfx, KeyPfx:
      # Skip over admin records until vertex sub-table reached
      while kData.keyPfx(kLen) < VtxPfx.ord:

        # Update Iterator and fetch next item
        rit.rocksdb_iter_next()
        if rit.rocksdb_iter_valid() == 0:
          break walkBody
        kData = rit.rocksdb_iter_key(addr kLen)
        # End while

    case pfx:
    of Oops, IdgPfx, VtxPfx:
      discard
    of KeyPfx:
      # Reposition search head to key sub-table
      while kData.keyPfx(kLen) < KeyPfx.ord:

        # Move search head to the first Merkle hash entry by seeking the same
        # vertex ID on the key table. This might skip over stale keys smaller
        # than the current one.
        let key = @[KeyPfx.ord.byte] & kData.keyXid(kLen).to(Blob)
        rit.rocksdb_iter_seek(cast[cstring](unsafeAddr key[0]), csize_t(kLen))

        # It is not clear what happens when the `key` does not exist. The guess
        # is that nothing would happen and the interation will proceed at the
        # next vertex position.
        kData = rit.rocksdb_iter_key(addr kLen)
        if KeyPfx.ord <= kData.keyPfx(kLen):
          # OK, reached Merkle hash table
          break

        # Update Iterator
        rit.rocksdb_iter_next()
        if rit.rocksdb_iter_valid() == 0:
          break walkBody
        kData = rit.rocksdb_iter_key(addr kLen)
        # End while

    # Fetch sub-table data
    while true:
      let kPfx = kData.keyPfx(kLen)
      if pfx.ord < kPfx:
        break walkBody # done

      let xid = kData.keyXid(kLen)
      if 0 < xid or pfx == IdgPfx:

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
      kData = rit.rocksdb_iter_key(addr kLen)
      count.inc
      # End while

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
