# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  std/[sequtils, strutils],
  eth/[common, trie/db],
  stew/byteutils,
  unittest2,
  ../../nimbus/common as nimbus_common,
  ../../nimbus/core/chain,
  ../../nimbus/db/storage_types,
  ../../nimbus/sync/snap/worker/db/snapdb_desc,
  ../replay/[pp, undump_blocks, undump_kvp],
  ./test_helpers

type
  UndumpDBKeySubType* = array[DBKeyKind.high.ord+2,int]

proc pp*(a: UndumpDBKeySubType): string

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc pp(a: ((int,int),UndumpDBKeySubType,UndumpDBKeySubType)): string =
  "([" & $a[0][0] & "," & $a[0][1] & "]," & a[1].pp & "," & a[2].pp & ")"


proc pairJoin[H,B](a: openArray[(seq[H],seq[B])]): (seq[H],seq[B]) =
  for w in a:
    result[0] &= w[0]
    result[1] &= w[1]

proc pairSplit[H,B](a: (seq[H],seq[B]); start,size: int): seq[(seq[H],seq[B])] =
  let
    a0Len = a[0].len
    a1Len = a[1].len
    minLen = min(a0Len,a1Len)

  var n = start
  while n < minLen:
    let top = min(n + size, minLen)
    result.add (a[0][n ..< top], a[1][n ..< top])
    n = top

  if minLen < a0Len:
    result.add (a[0][minLen ..< a0Len], seq[B].default)
  elif minLen < a1Len:
    result.add (seq[H].default, a[1][minLen ..< a1Len])

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc pp*(a: UndumpDBKeySubType): string =
  result = ($a).replace(" 0,",",")
               .replace(" 0]","]")
               .replace("[0,","[,")
               .replace(", ",",")
  let n = result.len
  if 3 < n and result[0] == '[' and result[^1] == ']':
    if result[^3] == ',' and result[^2] == ',':
      var p = n-4
      while result[p] == ',':
        p.dec
      if p == 0:
        result = "[]"
      else:
        result = result[0 .. p] & ",]"
    elif result[1] == ',' and result[2] == ',' and result[^2] != ',':
      var p = 3
      while result[p] == ',':
        p.inc
      result = "[," & result[p ..< n]

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_syncdbImportChainBlocks*(
    chn: ChainRef;
    filePath: string;
    lastNumber: uint64;
    noisy = true;
      ): uint64
      {.discardable.} =
  ## Import block chain (intended use for preparing database dumps)
  var count = 0
  for (h,b) in filePath.undumpBlocks:
    if h.len == 1 and h[0].blockNumber == 0:
      continue
    if h[^1].blockNumber < lastNumber.toBlockNumber:
      check chn.persistBlocks(h,b).isOk
      count.inc
      if 70 < count:
        noisy.say "*** import", " #", h[^1].blockNumber, ".."
        count = 0
      continue
    var
      sh: seq[BlockHeader]
      sb: seq[BlockBody]
    for n in 0 ..< h.len:
      if lastNumber.toBlockNumber < h[n].blockNumber:
        break
      sh.add h[n]
      sb.add b[n]
    if 0 < sh.len:
      check chn.persistBlocks(sh,sb).isOk
    result = sh[^1].blockNumber.truncate(typeof result)
    noisy.say "*** import", "ok #", result
    break


proc test_syncdbImportSnapshot*(
    chn: ChainRef;
    filePath: string;
    select = ChainRef(nil);
    noisy = true;
      ): ((int,int), UndumpDBKeySubType, UndumpDBKeySubType)
      {.discardable.} =
  ## Store snapshot dump. if the argument `select` is not `nil` then some
  ## data records are stored selectively only if they exist in the database
  ## addressed by the `select` argument.
  var count = 0
  for w in filePath.undumpKVP():
    var
      key: Blob
      storeOk = true
    case w.kind:
    of UndumpKey32:
      key = w.key32.toSeq
      if select.isNil or 0 < select.com.db.kvt.backend.toLegacy.get(key).len:
        result[0][0].inc
      else:
        storeOk = false
        result[0][1].inc
    of UndumpKey33:
      key = w.key33.toSeq
      let inx = min(w.key33[0], DBKeyKind.high.ord+1)

      #if inx == contractHash.ord:
      #  let digest = w.data.keccakHash.data.toSeq
      #  check (contractHash, digest) == (contractHash, key[1..32])

      #if not select.isNil:
      #  if inx in {3,4,5,18}:
      #    storeOk = false
      #  elif inx in {0,1,2,6} and select.com.db.db.get(key).len == 0:
      #    storeOk = false

      if storeOk:
        result[1][inx].inc
    of UndumpOther:
      key = w.other
      let inx = min(w.other[0], DBKeyKind.high.ord+1)
      result[2][inx].inc

    count.inc
    if (count mod 23456) == 0:
      noisy.say "*** import", result.pp, ".. "

    if storeOk:
      chn.com.db.kvt.backend.toLegacy.put(key, w.data)

  if (count mod 23456) != 0:
    noisy.say "*** import", result.pp, " ok"


proc test_syncdbAppendBlocks*(
    chn: ChainRef;
    filePath: string;
    pivotBlock: uint64;
    nItemsMax: int;
    noisy = true;
      ) =
  ## Verify seqHdr[0]` as pivot and add persistent blocks following
  # Make sure that pivot header is in database
  let
    blkLen = 33
    lastBlock = pivotBlock + max(1,nItemsMax).uint64
    kvt = chn.com.db.kvt.backend.toLegacy

    # Join (headers,blocks) pair in the range pivotBlock..lastBlock
    q = toSeq(filePath.undumpBlocks(pivotBlock,lastBlock)).pairJoin

    pivHash = q[0][0].blockHash
    pivNum = q[0][0].blockNumber

  # Verify pivot
  check 0 < kvt.get(pivHash.toBlockHeaderKey.toOpenArray).len
  check pivHash == kvt.get(pivNum.toBlockNumberKey.toOpenArray).decode(Hash256)

  # Set up genesis deputy.
  chn.com.startOfHistory = pivHash

  # Start after pivot and re-partition
  for (h,b) in q.pairSplit(1,blkLen):
    let persistentBlocksOk = chn.persistBlocks(h,b).isOk
    if not persistentBlocksOk:
      let (first,last) = ("#" & $h[0].blockNumber, "#" & $h[0].blockNumber)
      check (persistentBlocksOk,first,last) == (true,first,last)
      break

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
