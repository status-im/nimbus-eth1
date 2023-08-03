# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, sequtils, strformat, strutils],
  chronicles,
  eth/common,
  rocksdb,
  stew/byteutils,
  ../../nimbus/db/kvstore_rocksdb,
  ../../nimbus/sync/snap/[constants, range_desc, worker/db/hexary_desc],
  ./gunzip

type
  UndumpRecordKey* = enum
    UndumpKey32
    UndumpKey33
    UndumpOther

  UndumpRecord* = object
    case kind*: UndumpRecordKey
    of UndumpKey32:
      key32*: ByteArray32
    of UndumpKey33:
      key33*: ByteArray33
    of UndumpOther:
      other*: Blob
    data*: Blob
    id*: uint

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template ignExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    error "Ooops", `info`=info, name=($e.name), msg=(e.msg)

template say(args: varargs[untyped]) =
  # echo args
  discard

proc walkAllDb(
   rocky: RocksStoreRef;
   kvpFn: proc(k,v: Blob): bool;
      ) =
  ## Walk over all key-value pairs of the database (`RocksDB` only.)
  let
    rop = rocky.store.readOptions
    rit = rocky.store.db.rocksdb_create_iterator(rop)

  rit.rocksdb_iter_seek_to_first()
  while rit.rocksdb_iter_valid() != 0:
    # Read key-value pair
    var
      kLen, vLen: csize_t
    let
      kData = rit.rocksdb_iter_key(addr kLen)
      vData = rit.rocksdb_iter_value(addr vLen)

    # Store data
    let
      key = if kData.isNil: EmptyBlob
            else: kData.toOpenArrayByte(0,int(kLen)-1).toSeq
      value = if vData.isNil: EmptyBlob
              else: vData.toOpenArrayByte(0,int(vLen)-1).toSeq

    # Call key-value handler
    if kvpFn(key, value):
      break

    # Update Iterator (might overwrite kData/vdata)
    rit.rocksdb_iter_next()
    # End while

  rit.rocksdb_iter_destroy()

proc dumpAllDbImpl(
    rocky: RocksStoreRef;           # Persistent database handle
    fd: File;                       # File name to dump database records to
    nItemsMax: int;                 # Max number of items to dump
      ): int
      {.discardable.} =
  ## Dump datatbase records to argument file descriptor `fd`.
  var count = 0
  if not rocky.isNil and not fd.isNil:
    rocky.walkAllDb proc(k,v: Blob): bool {.raises: [IOError].} =
      count.inc
      fd.write k.toHex & ":" & v.toHex & " #" & $count & "\n"
      nItemsMax <= count
  count

# ------------------------------------------------------------------------------
# Public capture
# ------------------------------------------------------------------------------

proc dumpAllDb*(
    rocky: RocksStoreRef;           # Persistent database handle
    dumpFile = "snapdb.dmp";        # File name to dump database records to
    nItemsMax = high(int);          # Max number of items to dump
      ): int
      {.discardable.} =
  ## variant of `dumpAllDb()`
  var fd: File
  if fd.open(dumpFile, fmWrite):
    defer: fd.close
    ignExceptionOops("dumpAddDb"):
      result = rocky.dumpAllDbImpl(fd, nItemsMax)
    fd.flushFile

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpKVP*(gzFile: string): UndumpRecord =
  if not gzFile.fileExists:
    raiseAssert &"No such file: \"{gzFile}\""

  for lno,line in gzFile.gunzipLines:
    if line.len == 0 or line[0] == '#':
      continue

    let flds = line.split
    if 0 < flds.len:
      let kvp = flds[0].split(":")
      if kvp.len < 2:
        say &"*** line {lno}: expected \"<key>:<value>\" pair, got {line}"
        continue

      var id = 0u
      if 1 < flds.len and flds[1][0] == '#':
        let flds1Len = flds[1].len
        id = flds[1][1 ..< flds1Len].parseUInt

      case kvp[0].len:
      of 64:
        yield UndumpRecord(
          kind:  UndumpKey32,
          key32: ByteArray32.fromHex kvp[0],
          data:  kvp[1].hexToSeqByte,
          id:    id)
      of 66:
        yield UndumpRecord(
          kind:  UndumpKey33,
          key33: ByteArray33.fromHex kvp[0],
          data:  kvp[1].hexToSeqByte,
          id:    id)
      else:
        yield UndumpRecord(
          kind:  UndumpOther,
          other: kvp[1].hexToSeqByte,
          data:  kvp[1].hexToSeqByte,
          id:    id)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
