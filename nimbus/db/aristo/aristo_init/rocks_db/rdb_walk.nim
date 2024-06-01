# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  eth/common,
  stew/endians2,
  rocksdb,
  ../init_common,
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import
    chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walk*(
    rdb: RdbInst;
      ): tuple[pfx: StorageType, xid: uint64, data: Blob] =
  ## Walk over all key-value pairs of the database.
  ##
  ## Non-decodable entries are stepped over and ignored.
  block walkBody:
    let rit = rdb.store.openIterator().valueOr:
      when extraTraceMessages:
        trace logTxt "walk", pfx="all", error
      break walkBody
    defer: rit.close()

    for (key,val) in rit.pairs:
      if key.len == 9:
        if StorageType.high.ord < key[0]:
          break walkBody
        let
          pfx = StorageType(key[0])
          id = uint64.fromBytesBE key.toOpenArray(1, key.len - 1)
        yield (pfx, id, val)


iterator walk*(
    rdb: RdbInst;
    pfx: StorageType;
      ): tuple[xid: uint64, data: Blob] =
  ## Walk over key-value pairs of the table referted to by the argument `pfx`
  ## whic must be different from `Oops` and `AdmPfx`.
  ##
  ## Non-decodable entries are stepped over and ignored.
  ##
  block walkBody:
    let rit = rdb.store.openIterator().valueOr:
      when extraTraceMessages:
        echo ">>> walk (2) oops",
          " pfx=", pfx
        trace logTxt "walk", pfx, error
      break walkBody
    defer: rit.close()

    # Start at first entry not less than `<pfx> & 1`
    rit.seekToKey 1u64.toRdbKey pfx

    # Fetch sub-table data as long as the current key is acceptable
    while rit.isValid():
      let key = rit.key()
      if key.len == 9:
        if key[0] != pfx.ord.uint:
          break walkBody # done

        let val = rit.value()
        if val.len != 0:
          yield (uint64.fromBytesBE key.toOpenArray(1, key.high()), val)

      # Update Iterator
      rit.next()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
