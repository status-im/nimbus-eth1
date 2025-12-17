# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  stew/byteutils,
  json_rpc/rpcclient,
  web3/[eth_api_types, eth_api],
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  ../../eth_history/yaml_utils,
  ../../bridge/common/rpc_helpers

type BlockData* = object
  header*: string
  body*: string
  receipts*: string

proc toBlockData(
    header: Header, body: BlockBody, receipts: seq[StoredReceipt]
): BlockData =
  BlockData(
    header: rlp.encode(header).to0xHex(),
    body: rlp.encode(body).to0xHex(),
    receipts: rlp.encode(receipts).to0xHex(),
  )

proc exportBlock*(
    client: RpcClient, blockNumber: uint64, fileName: string
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let
    blockId = blockId(blockNumber)
    (header, body) = ?(await client.getBlockByNumber(blockId))
    receipts = ?(await client.getStoredReceiptsByNumber(blockId))

  toBlockData(header, body, receipts).dumpToYaml(fileName)
