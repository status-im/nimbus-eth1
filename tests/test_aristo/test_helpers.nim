# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/sequtils,
  eth/common,
  rocksdb,
  ../../nimbus/db/kvstore_rocksdb,
  ../../nimbus/sync/snap/constants,
  ../replay/pp

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walkAllDb*(rocky: RocksStoreRef): (int,Blob,Blob) =
  ## Walk over all key-value pairs of the database (`RocksDB` only.)
  let
    rop = rocky.store.readOptions
    rit = rocky.store.db.rocksdb_create_iterator(rop)
  defer:
    rit.rocksdb_iter_destroy()

  rit.rocksdb_iter_seek_to_first()
  var count = -1

  while rit.rocksdb_iter_valid() != 0:
    count .inc

    # Read key-value pair
    var
      kLen, vLen: csize_t
    let
      kData = rit.rocksdb_iter_key(addr kLen)
      vData = rit.rocksdb_iter_value(addr vLen)

    # Fetch data
    let
      key = if kData.isNil: EmptyBlob
            else: kData.toOpenArrayByte(0,int(kLen)-1).toSeq
      value = if vData.isNil: EmptyBlob
              else: vData.toOpenArrayByte(0,int(vLen)-1).toSeq

    yield (count, key, value)

    # Update Iterator (might overwrite kData/vdata)
    rit.rocksdb_iter_next()
    # End while

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
