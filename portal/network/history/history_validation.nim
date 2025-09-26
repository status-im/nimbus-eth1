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

export history_content

func validateBlockBody*(body: BlockBody, header: Header): Result[void, string] =
  ## Validate the block body against the txRoot, ommersHash and withdrawalsRoot
  ## from the header.
  ## The header is considered trusted, as in no checks are required whether the
  ## header fields are valid according to the rules of the applicable forks.

  # Short-path in case of no uncles
  if header.ommersHash == EMPTY_UNCLE_HASH:
    if body.uncles.len > 0:
      return err("Invalid ommers: expected no uncles")
  else:
    let calculatedOmmersHash = keccak256(rlp.encode(body.uncles))
      # TODO: avoid having to re-encode the uncles
    if calculatedOmmersHash != header.ommersHash:
      return err(
        "Invalid ommers hash: expected " & $header.ommersHash & " - got " &
          $calculatedOmmersHash
      )

  # Short-path in case of no transactions
  if header.txRoot == emptyRoot:
    if body.transactions.len > 0:
      return err("Invalid transactions: expected no transactions")
  else:
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
    let headerWithdrawalsRoot = header.withdrawalsRoot.value()
    # short-path in case of no withdrawals
    if headerWithdrawalsRoot == emptyRoot:
      if body.withdrawals.value().len > 0:
        return err("Invalid withdrawals: expected no withdrawals")
    else:
      let calculatedWithdrawalsRoot = orderedTrieRoot(body.withdrawals.value())
      if calculatedWithdrawalsRoot != headerWithdrawalsRoot:
        return err(
          "Invalid withdrawals root: expected " & $headerWithdrawalsRoot & " - got " &
            $calculatedWithdrawalsRoot
        )

  ok()

func validateReceipts*(
    storedReceipts: StoredReceipts, header: Header
): Result[void, string] =
  ## Validate the receipts against the receiptsRoot from the header.

  # Short-path in case of no receipts
  if header.receiptsRoot == emptyRoot:
    if storedReceipts.len > 0:
      err("Invalid receipts: expected no receipts")
    else:
      ok()
  else:
    let receipts = storedReceipts.to(seq[Receipt])

    let calculatedReceiptsRoot = orderedTrieRoot(receipts)
    if calculatedReceiptsRoot != header.receiptsRoot:
      err(
        "Unexpected receipt root: expected " & $header.receiptsRoot & " - got " &
          $calculatedReceiptsRoot
      )
    else:
      ok()

func validateContent*(
    content: BlockBody | StoredReceipts, header: Header
): Result[void, string] =
  type T = type(content)
  when T is BlockBody:
    validateBlockBody(content, header)
  elif T is StoredReceipts:
    validateReceipts(content, header)

func validateContent*(
    key: ContentKey, contentBytes: seq[byte], header: Header
): Result[void, string] =
  ## Validate the encoded content against the header.
  case key.contentType
  of blockBody:
    let content = ?decodeRlp(contentBytes, BlockBody)
    validateBlockBody(content, header)
  of receipts:
    let content = ?decodeRlp(contentBytes, StoredReceipts)
    validateReceipts(content, header)
