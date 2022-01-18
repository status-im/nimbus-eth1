# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_serialization, json_serialization/std/tables,
  stew/[byteutils, io2, results],
  eth/rlp,
  ./content_db,
  ./network/history/history_content

# Offline tool to populate the database with the current existing json files
# with block data. Might move to some other storage format later on. Perhaps
# https://github.com/status-im/nimbus-eth2/blob/stable/docs/e2store.md can be
# interesting.

type
  BlockData = object
    rlp: string
    number: uint64

  BlockDataTable = Table[string, BlockData]

proc populateHistoryDb*(dbDir: string, dataFile: string): Result[void, string] =
  let db = ContentDB.new(dbDir)

  let blockData = readAllFile(dataFile)
  if blockData.isErr(): # TODO: map errors
    return err("Failed reading data-file")

  let decoded =
    try:
      Json.decode(blockData.get(), BlockDataTable)
    except CatchableError as e:
      return err("Failed decoding json data-file: " & e.msg)

  # This is definitely the slowest part because of the hashing that happens in
  # toContentId()
  for k,v in decoded:
    try:
      var rlp = rlpFromHex(v.rlp)

      if rlp.enterList():
        # List that contains 3 items: Block header, body and receipts.
        # Only store block header for now.
        # When we want others, can use `rlp.skipElem()` and `rlp.rawData()`.

        # Prepare content key
        var blockHash: BlockHash
        blockHash.data = hexToByteArray[sizeof(BlockHash)](k)

        let contentKey = ContentKey(
          contentType: blockHeader,
          blockHeaderKey: ContentKeyType(chainId: 1'u16, blockHash: blockHash))

        db.put(contentKey.toContentId(), rlp.rawData())
    except CatchableError as e:
      return err("Failed decoding block hash or data: " & e.msg)

  ok()
