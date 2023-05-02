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

## Aristo (aka Patricia) DB trancoder test

import
  eth/common,
  stew/byteutils,
  unittest2,
  ../../nimbus/db/kvstore_rocksdb,
  ../../nimbus/db/aristo/[aristo_desc, aristo_debug, aristo_transcode],
  ../../nimbus/sync/snap/range_desc,
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_transcoderAccounts*(
    noisy = true;
    rocky: RocksStoreRef;
    stopAfter = high(int);
      ) =
  ## Transcoder tests on accounts database
  var
    adb = AristoDbRef()
    count = -1
  for (n, key,value) in rocky.walkAllDb():
    count = n

    # RLP <-> NIM object mapping
    let node0 = value.decode(NodeRef)
    block:
      let blob0 = rlp.encode node0
      if value != blob0:
        check value.len == blob0.len
        check value == blob0
        noisy.say "***", "count=", count, " value=", value.rlpFromBytes.inspect
        noisy.say "***", "count=", count, " blob0=", blob0.rlpFromBytes.inspect

    # Provide DbRecord with dummy links and expanded payload
    var node = node0
    case node.kind:
    of aristo_desc.Dummy:
      discard
    of aristo_desc.Leaf:
      let account = node.lData.blob.decode(Account)
      node.lData = PayloadRef(kind: AccountData, account: account)
      discard adb.keyToVtxID node.lData.account.storageRoot.to(NodeKey)
      discard adb.keyToVtxID node.lData.account.codeHash.to(NodeKey)
    of aristo_desc.Extension:
      # key -> vtx mapping for pretty printer
      node.eVtx = adb.keyToVtxID node.eKey
    of aristo_desc.Branch:
      for n in 0..15:
        # key[n] -> vtx[n] mapping for pretty printer
        node.bVtx[n] = adb.keyToVtxID node.bKey[n]

    # This NIM object must match to the same RLP encoded byte stream
    block:
      var blob1 = rlp.encode node
      if value != blob1:
        check value.len == blob1.len
        check value == blob1
        noisy.say "***", "count=", count, " value=", value.rlpFromBytes.inspect
        noisy.say "***", "count=", count, " blob1=", blob1.rlpFromBytes.inspect

    # NIM object <-> DbRecord mapping
    let dbr = node.toDbRecord
    var node1 = dbr.fromDbRecord

    block:
      # `fromDbRecord()` will always decode to `BlobData` type payload
      if node1.kind == aristo_desc.Leaf:
        let account = node1.lData.blob.decode(Account)
        node1.lData = PayloadRef(kind: AccountData, account: account)
      if node != node1:
        check node == node1
        noisy.say "***", "count=", count, " node=", node.pp(adb)
        noisy.say "***", "count=", count, " node1=", node1.pp(adb)

    # Serialise back with expanded `AccountData` type payload (if any)
    let dbr1 = node1.toDbRecord
    block:
      if dbr != dbr1:
        check dbr == dbr1
        noisy.say "***", "count=", count, " dbr=", dbr.toHex
        noisy.say "***", "count=", count, " dbr1=", dbr1.toHex

    # Serialise back as is
    let dbr2 = dbr.fromDbRecord.toDbRecord
    block:
      if dbr != dbr2:
        check dbr == dbr2
        noisy.say "***", "count=", count, " dbr=", dbr.toHex
        noisy.say "***", "count=", count, " dbr2=", dbr2.toHex

  noisy.say "***", "records visited: ", count + 1

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
