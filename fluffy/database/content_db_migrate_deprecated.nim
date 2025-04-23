# Fluffy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  metrics,
  stint,
  results,
  stew/ptrops,
  sqlite3_abi,
  eth/db/kvstore,
  eth/db/kvstore_sqlite3,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp, transactions_rlp],
  ../network/history/history_content,
  ../network/history/history_type_conversions,
  ../network/state/state_utils,
  ../network/state/state_content,
  ../network/history/content/content_values_deprecated

export kvstore_sqlite3

type
  ContentPair = tuple[contentKey: array[32, byte], contentItem: seq[byte]]

  ContentDBDeprecated* = ref object
    backend: SqStoreRef
    kv: KvStoreRef
    selectAllStmt: SqliteStmt[NoParams, ContentPair]
    deleteBatchStmt: SqliteStmt[NoParams, void]
    updateBatchStmt: SqliteStmt[NoParams, void]

func isWithoutProofImpl(content: openArray[byte]): bool =
  let headerWithProof = decodeSsz(content, BlockHeaderWithProofDeprecated).valueOr:
    # Leave all other content as it is
    return false

  if headerWithProof.proof.proofType ==
      BlockHeaderProofType.historicalHashesAccumulatorProof:
    false
  elif headerWithProof.proof.proofType == BlockHeaderProofType.none:
    true
  else:
    false

func isWithoutProof*(
    ctx: SqliteContext, n: cint, v: SqliteValue
) {.cdecl, gcsafe, raises: [].} =
  doAssert(n == 1)

  let
    ptrs = makeUncheckedArray(v)
    blob1Len = sqlite3_value_bytes(ptrs[][0])

  if isWithoutProofImpl(makeOpenArray(sqlite3_value_blob(ptrs[][0]), byte, blob1Len)):
    ctx.sqlite3_result_int(cint 1)
  else:
    ctx.sqlite3_result_int(cint 0)

func isWithInvalidEncodingImpl(content: openArray[byte]): bool =
  let headerWithProof = decodeSsz(content, BlockHeaderWithProofDeprecated).valueOr:
    # Leave all other content as it is
    return false

  if headerWithProof.proof.proofType ==
      BlockHeaderProofType.historicalHashesAccumulatorProof: true else: false

func isWithInvalidEncoding*(
    ctx: SqliteContext, n: cint, v: SqliteValue
) {.cdecl, gcsafe, raises: [].} =
  doAssert(n == 1)

  let
    ptrs = makeUncheckedArray(v)
    blobLen = sqlite3_value_bytes(ptrs[][0])

  if isWithInvalidEncodingImpl(
    makeOpenArray(sqlite3_value_blob(ptrs[][0]), byte, blobLen)
  ):
    ctx.sqlite3_result_int(cint 1)
  else:
    ctx.sqlite3_result_int(cint 0)

func adjustContentImpl(a: openArray[byte]): seq[byte] =
  let headerWithProof = decodeSsz(a, BlockHeaderWithProofDeprecated).valueOr:
    raiseAssert("Should not occur as decoding check is already done")

  let accumulatorProof = headerWithProof.proof.historicalHashesAccumulatorProof
  let adjustedContent = BlockHeaderWithProof(
    header: headerWithProof.header,
    proof: ByteList[MAX_HEADER_PROOF_LENGTH].init(SSZ.encode(accumulatorProof)),
  )

  SSZ.encode(adjustedContent)

func adjustContent*(
    ctx: SqliteContext, n: cint, v: SqliteValue
) {.cdecl, gcsafe, raises: [].} =
  doAssert(n == 1)

  let
    ptrs = makeUncheckedArray(v)
    blobLen = sqlite3_value_bytes(ptrs[][0])

    bytes =
      adjustContentImpl(makeOpenArray(sqlite3_value_blob(ptrs[][0]), byte, blobLen))

  sqlite3_result_blob(ctx, baseAddr bytes, cint bytes.len, SQLITE_TRANSIENT)

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

## Public calls to get database size, content size and similar.

proc new*(
    T: type ContentDBDeprecated,
    path: string,
    inMemory = false,
    manualCheckpoint = false,
): ContentDBDeprecated =
  let db =
    if inMemory:
      SqStoreRef.init("", "fluffy-test", inMemory = true).expect(
        "working database (out of memory?)"
      )
    else:
      SqStoreRef.init(path, "fluffy", manualCheckpoint = false).expectDb()

  db.createCustomFunction("isWithoutProof", 1, isWithoutProof).expect(
    "Custom function isWithoutProof creation OK"
  )

  db.createCustomFunction("isWithInvalidEncoding", 1, isWithInvalidEncoding).expect(
    "Custom function isWithInvalidEncoding creation OK"
  )

  db.createCustomFunction("adjustContent", 1, adjustContent).expect(
    "Custom function adjustContent creation OK"
  )

  let selectAllStmt =
    db.prepareStmt("SELECT key, value FROM kvstore", NoParams, ContentPair)[]

  let deleteBatchStmt = db.prepareStmt(
    "DELETE FROM kvstore WHERE key IN (SELECT key FROM kvstore WHERE isWithoutProof(value) == 1)",
    NoParams, void,
  )[]

  let updateBatchStmt = db.prepareStmt(
    "UPDATE kvstore SET value = adjustContent(value) WHERE key IN (SELECT key FROM kvstore WHERE isWithInvalidEncoding(value) == 1)",
    NoParams, void,
  )[]

  let kvStore = kvStore db.openKvStore().expectDb()

  let contentDb = ContentDBDeprecated(
    kv: kvStore,
    backend: db,
    selectAllStmt: selectAllStmt,
    deleteBatchStmt: deleteBatchStmt,
    updateBatchStmt: updateBatchStmt,
  )

  contentDb

template disposeSafe(s: untyped): untyped =
  if distinctBase(s) != nil:
    s.dispose()
    s = typeof(s)(nil)

proc close*(db: ContentDBDeprecated) =
  db.selectAllStmt.disposeSafe()
  db.deleteBatchStmt.disposeSafe()
  db.updateBatchStmt.disposeSafe()
  discard db.kv.close()

proc deleteAllHeadersWithoutProof*(db: ContentDBDeprecated) =
  notice "ContentDB migration: deleting all headers without proof"
  db.deleteBatchStmt.exec().expectDb()
  notice "ContentDB migration done"

proc updateAllHeadersWithInvalidEncoding*(db: ContentDBDeprecated) =
  notice "ContentDB migration: updating all headers with invalid encoding"
  db.updateBatchStmt.exec().expectDb()
  notice "ContentDB migration done"

proc iterateAllAndCountTypes*(db: ContentDBDeprecated) =
  ## Ugly debugging call to print out count of content types in case of issues.
  var
    contentPair: ContentPair
    contentTotal = 0
    contentOldHeaders = 0
    contentNewHeaders = 0
    contentBodies = 0
    contentReceipts = 0
    contentAccount = 0
    contentContract = 0
    contentCode = 0
    contentOther = 0

  notice "ContentDB type count: iterating over all content"
  for e in db.selectAllStmt.exec(contentPair):
    contentTotal.inc()
    block:
      let res = decodeSsz(contentPair.contentItem, BlockHeaderWithProofDeprecated)
      if res.isOk():
        if decodeRlp(res.value().header.asSeq(), Header).isOk():
          contentOldHeaders.inc()
          continue
    block:
      let res = decodeSsz(contentPair.contentItem, BlockHeaderWithProof)
      if res.isOk():
        if decodeRlp(res.value().header.asSeq(), Header).isOk():
          contentNewHeaders.inc()
          continue

    block:
      let res = decodeSsz(contentPair.contentItem, PortalReceipts)
      if res.isOk():
        if fromPortalReceipts(seq[Receipt], res.value()).isOk():
          contentReceipts.inc()
          continue

    block:
      let res = decodeSsz(contentPair.contentItem, PortalBlockBodyShanghai)
      if res.isOk():
        if fromPortalBlockBody(BlockBody, res.value()).isOk():
          contentBodies.inc()
          continue

    block:
      let res = decodeSsz(contentPair.contentItem, PortalBlockBodyLegacy)
      if res.isOk():
        if fromPortalBlockBody(BlockBody, res.value()).isOk():
          contentBodies.inc()
          continue

    block:
      let res = decodeSsz(contentPair.contentItem, AccountTrieNodeRetrieval)
      if res.isOk():
        if rlpDecodeAccountTrieNode(res.value().node).isOk():
          contentAccount.inc()
          continue

    block:
      let res = decodeSsz(contentPair.contentItem, ContractTrieNodeRetrieval)
      if res.isOk():
        if rlpDecodeContractTrieNode(res.value().node).isOk():
          contentContract.inc()
          continue

    block:
      let res = decodeSsz(contentPair.contentItem, ContractCodeRetrieval)
      if res.isOk():
        contentCode.inc()
        continue

    contentOther.inc()

  notice "ContentDB type count done: ",
    contentTotal, contentOldHeaders, contentNewHeaders, contentReceipts, contentBodies,
    contentAccount, contentContract, contentCode, contentOther
