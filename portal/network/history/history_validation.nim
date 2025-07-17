# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/trie/ordered_trie,
  eth/common/[headers_rlp, blocks_rlp, receipts, hashes],
  ./history_content

func validateBlockBody*(body: BlockBody, header: Header): Result[void, string] =
  ## Validate the block body against the txRoot, ommersHash and withdrawalsRoot
  ## from the header.
  ## TODO: could add block number vs empty ommersHash + existing withdrawalsRoot check
  let calculatedOmmersHash = keccak256(rlp.encode(body.uncles))
    # TODO: avoid having to re-encode the uncles
  if calculatedOmmersHash != header.ommersHash:
    return err(
      "Invalid ommers hash: expected " & $header.ommersHash & " - got " &
        $calculatedOmmersHash
    )

  let calculatedTxsRoot = orderedTrieRoot(body.transactions)
  if calculatedTxsRoot != header.txRoot:
    return err(
      "Invalid transactions root: expected " & $header.txRoot & " - got " &
        $calculatedTxsRoot
    )

  if header.withdrawalsRoot.isSome() and body.withdrawals.isNone() or
      header.withdrawalsRoot.isNone() and body.withdrawals.isSome():
    return err("Invalid withdrawals")

  if header.withdrawalsRoot.isSome() and body.withdrawals.isSome():
    let
      calculatedWithdrawalsRoot = orderedTrieRoot(body.withdrawals.value())
      headerWithdrawalsRoot = header.withdrawalsRoot.get()
    if calculatedWithdrawalsRoot != headerWithdrawalsRoot:
      return err(
        "Invalid withdrawals root: expected " & $headerWithdrawalsRoot & " - got " &
          $calculatedWithdrawalsRoot
      )

  ok()

func validateReceipts*(receipts: Receipts, header: Header): Result[void, string] =
  ## Validate the receipts against the receiptsRoot from the header.
  let calculatedReceiptsRoot = orderedTrieRoot(receipts)
  if calculatedReceiptsRoot != header.receiptsRoot:
    err(
      "Unexpected receipt root: expected " & $header.receiptsRoot & " - got " &
        $calculatedReceiptsRoot
    )
  else:
    ok()

func validateContent*(
    content: BlockBody | Receipts, header: Header
): Result[void, string] =
  type T = type(content)
  when T is BlockBody:
    validateBlockBody(content, header)
  elif T is Receipts:
    validateReceipts(content, header)

func validateContent*(
    key: ContentKey, contentBytes: seq[byte], header: Header
): Result[void, string] =
  ## Validate the encoded content against the header.
  case key.contentType
  of unused:
    raiseAssert("ContentKey contentType: unused")
  of blockBody:
    let content = ?decodeRlp(contentBytes, BlockBody)
    validateBlockBody(content, header)
  of receipts:
    let content = ?decodeRlp(contentBytes, Receipts)
    validateReceipts(content, header)
