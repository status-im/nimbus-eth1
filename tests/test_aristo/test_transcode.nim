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
  ../../nimbus/db/aristo/[
    aristo_desc, aristo_debug, aristo_error, aristo_transcode, aristo_vid],
  "."/[test_aristo_cache, test_helpers]

type
  TesterDesc = object
    prng: uint32                       ## random state

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

proc rand[W: SomeInteger|VertexID](ap: var TesterDesc; T: type W): T =
  var a: array[sizeof T,byte]
  for n in 0 ..< sizeof T:
    a[n] = ap.prng.posixPrngRand().byte
  when sizeof(T) == 1:
    let w = uint8.fromBytesBE(a).T
  when sizeof(T) == 2:
    let w = uint16.fromBytesBE(a).T
  when sizeof(T) == 4:
    let w = uint32.fromBytesBE(a).T
  else:
    let w = uint64.fromBytesBE(a).T
  when T is SomeUnsignedInt:
    # That way, `fromBytesBE()` can be applied to `uint`
    result = w
  else:
    # That way the result is independent of endianness
    (addr result).copyMem(unsafeAddr w, sizeof w)

proc vidRand(td: var TesterDesc; bits = 19): VertexID =
  if bits < 64:
    let
      mask = (1u64 shl max(1,bits)) - 1
      rval = td.rand uint64
    (rval and mask).VertexID
  else:
    td.rand VertexID

proc init(T: type TesterDesc; seed: int): TesterDesc =
  result.prng = (seed and 0x7fffffff).uint32

# -----

proc getOrEmpty(rc: Result[Blob,AristoError]; noisy = true): Blob =
  if rc.isOk:
    return rc.value
  noisy.say "***", "error=", rc.error

proc `+`(a: VertexID, b: int): VertexID =
  (a.uint64 + b.uint64).VertexID

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_transcodeAccounts*(
    noisy = true;
    rocky: RocksStoreRef;
    stopAfter = high(int);
      ) =
  ## Transcoder tests on accounts database
  var
    adb = AristoDbRef()
    count = -1
  for (n, key,value) in rocky.walkAllDb():
    if stopAfter < n:
      break
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

    # Provide DbRecord with dummy links and expanded payload. Registering the
    # node as vertex and re-converting it does the job
    var node = node0.updated(adb)
    if node.isError:
      check node.error == AristoError(0)
    else:
      case node.vType:
      of aristo_desc.Leaf:
        let account = node.lData.blob.decode(Account)
        node.lData = PayloadRef(pType: AccountData, account: account)
        discard adb.keyToVtxID node.lData.account.storageRoot.to(NodeKey)
        discard adb.keyToVtxID node.lData.account.codeHash.to(NodeKey)
      of aristo_desc.Extension:
        # key <-> vtx correspondence
        check node.key[0] == node0.key[0]
        check not node.eVid.isZero
      of aristo_desc.Branch:
        for n in 0..15:
          # key[n] <-> vtx[n] correspondence
          check node.key[n] == node0.key[n]
          check node.key[n].isEmpty == node.bVid[n].isZero
          if node.key[n].isEmpty != node.bVid[n].isZero:
            echo ">>> node=", node.pp

    # This NIM object must match to the same RLP encoded byte stream
    block:
      var blob1 = rlp.encode node
      if value != blob1:
        check value.len == blob1.len
        check value == blob1
        noisy.say "***", "count=", count, " value=", value.rlpFromBytes.inspect
        noisy.say "***", "count=", count, " blob1=", blob1.rlpFromBytes.inspect

    # NIM object <-> DbRecord mapping
    let dbr = node.blobify.getOrEmpty(noisy)
    var node1 = dbr.deblobify.asNode(adb)
    if node1.isError:
      check node1.error == AristoError(0)

    block:
      # `deblobify()` will always decode to `BlobData` type payload
      if node1.vType == aristo_desc.Leaf:
        let account = node1.lData.blob.decode(Account)
        node1.lData = PayloadRef(pType: AccountData, account: account)

      if node != node1:
        check node == node1
        noisy.say "***", "count=", count, " node=", node.pp(adb)
        noisy.say "***", "count=", count, " node1=", node1.pp(adb)

    # Serialise back with expanded `AccountData` type payload (if any)
    let dbr1 = node1.blobify.getOrEmpty(noisy)
    block:
      if dbr != dbr1:
        check dbr == dbr1
        noisy.say "***", "count=", count, " dbr=", dbr.toHex
        noisy.say "***", "count=", count, " dbr1=", dbr1.toHex

    # Serialise back as is
    let dbr2 = dbr.deblobify.asNode(adb).blobify.getOrEmpty(noisy)
    block:
      if dbr != dbr2:
        check dbr == dbr2
        noisy.say "***", "count=", count, " dbr=", dbr.toHex
        noisy.say "***", "count=", count, " dbr2=", dbr2.toHex

  noisy.say "***", "records visited: ", count + 1


proc test_transcodeVidRecycleLists*(noisy = true; seed = 42) =
  ## Transcode VID lists held in `AristoDb` descriptor
  var td = TesterDesc.init seed
  let db = AristoDbRef()

  # Add some randum numbers
  block:
    let first = td.vidRand()
    db.vidDispose first

    var
      expectedVids = 1
      count = 1
    # Feed some numbers used and some discaded
    while expectedVids < 5 or count < 5 + expectedVids:
      count.inc
      let vid = td.vidRand()
      expectedVids += (vid < first).ord
      db.vidDispose vid

    check db.vGen.len == expectedVids
    noisy.say "***", "vids=", db.vGen.len, " discarded=", count-expectedVids

  # Serialise/deserialise
  block:
    let dbBlob = db.blobify

    # Deserialise
    let db1 = block:
      let rc = dbBlob.deblobify AristoDbRef
      if rc.isErr:
        check rc.isOk
      rc.get(otherwise = AristoDbRef())

    check db.vGen == db1.vGen

  # Make sure that recycled numbers are fetched first
  let topVid = db.vGen[^1]
  while 1 < db.vGen.len:
    let w = db.vidFetch()
    check w < topVid
  check db.vGen.len == 1 and db.vGen[0] == topVid

  # Get some consecutive vertex IDs
  for n in 0 .. 5:
    let w = db.vidFetch()
    check w == topVid + n
    check db.vGen.len == 1

  # Repeat last test after clearing the cache
  db.vGen.setLen(0)
  for n in 0 .. 5:
    let w = db.vidFetch()
    check w == 1.VertexID + n
    check db.vGen.len == 1

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
