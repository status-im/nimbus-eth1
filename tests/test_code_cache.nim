# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/[atomics, importutils, random],
  unittest2,
  taskpools,
  eth/common/[addresses, hashes],
  ../execution_chain/db/core_db,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/db/ledger {.all.}

privateAccess(LedgerRef)

proc cacheCode(codeHash: Hash32, code: CodeBytesRef) =
  let blob = code.toBlob()
  insertCached(codeHash, blob)
  blob.release()

proc liveBlobs(): int =
  liveCodeBlobs.load(moRelaxed)

proc syntheticCode(len, seed: int): seq[byte] =
  ## Random mix of PUSH instructions whose data often contains 0x5b, real
  ## JUMPDESTs and plain one-byte opcodes
  var rng = initRand(seed)
  result = newSeq[byte](len)
  var i = 0
  while i < len:
    case rng.rand(3)
    of 0:
      let n = 1 + rng.rand(31)
      result[i] = byte(0x5f + n)
      for j in 1 .. n:
        if i + j < len:
          result[i + j] = if rng.rand(1) == 0: 0x5b else: byte(rng.rand(255))
      i += n + 1
    of 1:
      result[i] = 0x5b
      inc i
    else:
      result[i] = byte(rng.rand(0x5f))
      inc i

proc validPositions(code: openArray[byte]): seq[bool] =
  ## Linear reference scan: every position that is not PUSH data is valid
  result = newSeq[bool](code.len)
  var i = 0
  while i < code.len:
    result[i] = true
    let op = int(code[i])
    if op >= 0x60 and op <= 0x7f:
      i += op - 0x5f
    inc i

proc checkRandomOrder(code: CodeBytesRef, expected: seq[bool], seed: int): bool =
  var rng = initRand(seed)
  var positions = newSeq[int](expected.len)
  for i in 0 ..< positions.len:
    positions[i] = i
  rng.shuffle(positions)
  for p in positions:
    if code.isValidOpcode(p) != expected[p]:
      return false
  code.isValidOpcode(expected.len) == false

proc scanTask(
    blob: CodeBlob, expected: ptr UncheckedArray[bool], len, seed: int,
    mismatches: ptr Atomic[int]) {.gcsafe, raises: [].} =
  let code = CodeBytesRef.fromBlob(blob)
  var rng = initRand(seed)
  for _ in 0 ..< 4 * len:
    let p = rng.rand(len - 1)
    if code.isValidOpcode(p) != expected[p]:
      discard mismatches[].fetchAdd(1, moRelaxed)

const churnKeys = 32

proc churnTask(seed, iters: int, mismatches: ptr Atomic[int]) {.gcsafe, raises: [].} =
  var
    codes: array[churnKeys, seq[byte]]
    hashes: array[churnKeys, Hash32]
    expected: array[churnKeys, seq[bool]]
  for k in 0 ..< churnKeys:
    codes[k] = syntheticCode(64 + 97 * k, k)
    hashes[k] = keccak256(codes[k])
    expected[k] = validPositions(codes[k])

  var rng = initRand(seed)
  for _ in 0 ..< iters:
    let k = rng.rand(churnKeys - 1)
    var blob = acquireCached(hashes[k])
    if blob.isNil:
      blob = newCodeBlob(codes[k])
      insertCached(hashes[k], blob)
    let
      code = CodeBytesRef.fromBlob(blob)
      p = rng.rand(codes[k].len - 1)
    if code.len != codes[k].len or code.isValidOpcode(p) != expected[k][p] or
        not (code == codes[k]):
      discard mismatches[].fetchAdd(1, moRelaxed)
    blob.release()

suite "Shared code cache":
  setup:
    resetCodeCache(threadSafe = false)
    let
      memDB = newCoreDbRef DefaultDbMemory
      txFrame = memDB.baseTxFrame()
      address1 = address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6"
      address2 = address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec7"
      code1 = syntheticCode(300, 1)
      code2 = syntheticCode(500, 2)

  teardown:
    resetCodeCache(threadSafe = false)
    check liveBlobs() == 0

  test "isValidOpcode resumes on an opcode boundary":
    for shared in [false, true]:
      block:
        let inline = CodeBytesRef.init(@[0x61'u8, 0x5b, 0x60, 0x5b])
        let code =
          if shared: CodeBytesRef.fromBlob(inline.toBlob()) else: inline
        check:
          not code.isValidOpcode(1)
          code.isValidOpcode(3)
        if shared:
          code.codeBlob.release()
      block:
        let inline = CodeBytesRef.init(@[0x61'u8, 0x5b, 0x60, 0x61, 0x5b, 0x5b, 0x5b])
        let code =
          if shared: CodeBytesRef.fromBlob(inline.toBlob()) else: inline
        check:
          not code.isValidOpcode(1)
          not code.isValidOpcode(4)
          code.isValidOpcode(6)
        if shared:
          code.codeBlob.release()

  test "random query order matches a linear scan":
    for seed in 0 ..< 8:
      let
        bytes = syntheticCode(1000 + 731 * seed, seed)
        expected = validPositions(bytes)
        inline = CodeBytesRef.init(bytes)
        blob = inline.toBlob()
        shared = CodeBytesRef.fromBlob(blob)
      check:
        checkRandomOrder(inline, expected, seed)
        checkRandomOrder(shared, expected, seed + 100)
        inline.scannedUpTo <= bytes.len
        shared.scannedUpTo <= bytes.len
      blob.release()

  test "ledger pins are released on dispose":
    block:
      let writer = LedgerRef.init(txFrame)
      writer.setCode(address1, code1)
      writer.setCode(address2, code1)
      writer.persist()
      writer.dispose()
    check liveBlobs() == 0

    let ledger = LedgerRef.init(txFrame)
    check:
      ledger.getCode(address1) == code1
      ledger.getCode(address2) == code1
      ledger.getCode(address1).sharesBlob(ledger.getCode(address2))
      ledger.getCode(address1).persisted
      ledger.codePins.len == 2
      liveBlobs() == 1
      codeCacheLen() == 1
    ledger.dispose()
    check:
      ledger.codePins.len == 0
      liveBlobs() == 1
    resetCodeCache(threadSafe = false)
    check liveBlobs() == 0

  test "persist with clearCache and reinit release pins":
    block:
      let writer = LedgerRef.init(txFrame)
      writer.setCode(address1, code1)
      writer.persist()
      writer.dispose()

    let ledger = LedgerRef.init(txFrame)
    check ledger.getCode(address1) == code1
    check ledger.codePins.len == 1
    ledger.persist(clearCache = true)
    check ledger.codePins.len == 0
    check ledger.getCode(address1) == code1
    check ledger.codePins.len == 1

    let child = txFrame.txFrameBegin()
    ledger.reinit(child)
    check ledger.codePins.len == 0
    check ledger.getCode(address1) == code1
    check ledger.codePins.len == 1
    ledger.dispose()
    check liveBlobs() == codeCacheLen()

  test "evicted blob stays alive while pinned":
    resetCodeCache(1, threadSafe = false)
    block:
      let writer = LedgerRef.init(txFrame)
      writer.setCode(address1, code1)
      writer.setCode(address2, code2)
      writer.persist()
      writer.dispose()

    let
      ledger = LedgerRef.init(txFrame)
      first = ledger.getCode(address1)
      expected = validPositions(code1)
    check:
      first == code1
      ledger.getCode(address2) == code2
      codeCacheLen() == 1
      liveBlobs() == 2
      first == code1
      checkRandomOrder(first, expected, 7)
    ledger.dispose()
    check liveBlobs() == 1

  test "inline initcode promoted at root commit keeps its jump filter":
    let
      ledger = LedgerRef.init(txFrame)
      codeHash = keccak256(code1)
      executed = CodeBytesRef.init(code1)
      outer = ledger.beginSavePoint()
    discard executed.isValidOpcode(code1.len - 1)
    ledger.cacheCodeOnCommit(codeHash, executed)
    check ledger.peekCode(codeHash).isNone
    ledger.commit(outer)
    let
      admitted = ledger.peekCode(codeHash).get
      again = ledger.peekCode(codeHash).get
    check:
      admitted == code1
      admitted.scannedUpTo == executed.scannedUpTo
      not admitted.sharesBlob(executed)
      admitted.sharesBlob(again)
      not admitted.persisted
      checkRandomOrder(admitted, validPositions(code1), 3)
    ledger.dispose()

  test "concurrent jump validation on one shared blob":
    let
      bytes = syntheticCode(60_000, 42)
      expected = validPositions(bytes)
      blob = newCodeBlob(bytes)
    var
      mismatches: Atomic[int]
      tp = Taskpool.new(numThreads = 8)
    for t in 0 ..< 16:
      tp.spawn scanTask(
        blob, cast[ptr UncheckedArray[bool]](unsafeAddr expected[0]), bytes.len, t,
        addr mismatches)
    tp.syncAll()
    tp.shutdown()
    check:
      mismatches.load(moRelaxed) == 0
      CodeBytesRef.fromBlob(blob).scannedUpTo == bytes.len
    blob.release()

  test "concurrent cache churn keeps blob accounting balanced":
    resetCodeCache(8, threadSafe = true)
    var
      mismatches: Atomic[int]
      tp = Taskpool.new(numThreads = 8)
    for t in 0 ..< 16:
      tp.spawn churnTask(t, 2000, addr mismatches)
    tp.syncAll()
    tp.shutdown()
    check:
      mismatches.load(moRelaxed) == 0
      liveBlobs() == codeCacheLen()
