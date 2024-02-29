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
  rocksdb/lib/librocksdb,
  rocksdb,
  ./rdb_desc

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walk*(rdb: RdbInst): tuple[key: Blob, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  let
    readOptions = rocksdb_readoptions_create()
    rit = rdb.store.cPtr.rocksdb_create_iterator(readOptions)
  defer:
    rit.rocksdb_iter_destroy()
    readOptions.rocksdb_readoptions_destroy()

  rit.rocksdb_iter_seek_to_first()
  while rit.rocksdb_iter_valid() != 0:
    var kLen: csize_t
    let kData = rit.rocksdb_iter_key(addr kLen)

    if not kData.isNil and 0 < kLen:
      var vLen: csize_t
      let vData = rit.rocksdb_iter_value(addr vLen)

      if not vData.isNil and 0 < vLen:
        let
          key = kData.toOpenArrayByte(0,int(kLen)-1).toSeq
          data = vData.toOpenArrayByte(0,int(vLen)-1).toSeq
        yield (key,data)

    # Update Iterator (might overwrite kData/vdata)
    rit.rocksdb_iter_next()

    # End while

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
