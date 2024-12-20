# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp, transactions_rlp],
  ./history_content

export history_content, headers_rlp, blocks_rlp, receipts_rlp

## Calls to go from SSZ decoded Portal types to RLP fully decoded EL types

func fromPortalBlockBody*(
    T: type BlockBody, body: PortalBlockBodyLegacy
): Result[T, string] =
  ## Get the EL BlockBody from the SSZ-decoded `PortalBlockBodyLegacy`.
  try:
    var transactions: seq[Transaction]
    for tx in body.transactions:
      transactions.add(rlp.decode(tx.asSeq(), Transaction))

    let uncles = rlp.decode(body.uncles.asSeq(), seq[Header])

    ok(BlockBody(transactions: transactions, uncles: uncles))
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

func fromPortalBlockBody*(
    T: type BlockBody, body: PortalBlockBodyShanghai
): Result[T, string] =
  ## Get the EL BlockBody from the SSZ-decoded `PortalBlockBodyShanghai`.
  try:
    var transactions: seq[Transaction]
    for tx in body.transactions:
      transactions.add(rlp.decode(tx.asSeq(), Transaction))

    var withdrawals: seq[Withdrawal]
    for w in body.withdrawals:
      withdrawals.add(rlp.decode(w.asSeq(), Withdrawal))

    ok(
      BlockBody(
        transactions: transactions,
        uncles: @[], # Uncles must be empty, this is verified in `validateBlockBody`
        withdrawals: Opt.some(withdrawals),
      )
    )
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

func fromPortalBlockBodyBytes*(bytes: openArray[byte]): Result[BlockBody, string] =
  if (let res = decodeSsz(bytes, PortalBlockBodyLegacy); res.isOk()):
    BlockBody.fromPortalBlockBody(res.value())
  elif (let res = decodeSsz(bytes, PortalBlockBodyShanghai); res.isOk()):
    BlockBody.fromPortalBlockBody(res.value())
  else:
    err("Invalid Portal BlockBody encoding")

func fromPortalBlockBodyOrRaise*(
    T: type BlockBody, body: PortalBlockBodyLegacy | PortalBlockBodyShanghai
): T =
  ## Get the EL BlockBody from one of the SSZ-decoded Portal BlockBody types.
  ## Will raise Assertion in case of invalid RLP encodings. Only use for data
  ## has been validated before!
  let res = BlockBody.fromPortalBlockBody(body)
  if res.isOk():
    res.get()
  else:
    raiseAssert(res.error)

func fromPortalReceipts*(
    T: type seq[Receipt], receipts: PortalReceipts
): Result[T, string] =
  ## Get the full decoded EL seq[Receipt] from the SSZ-decoded `PortalReceipts`.
  try:
    var res: seq[Receipt]
    for receipt in receipts:
      res.add(rlp.decode(receipt.asSeq(), Receipt))

    ok(res)
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

## Calls to convert EL block types to the Portal types.

func fromBlockBody*(T: type PortalBlockBodyLegacy, body: BlockBody): T =
  var transactions: Transactions
  for tx in body.transactions:
    discard transactions.add(TransactionByteList(rlp.encode(tx)))

  let uncles = Uncles(rlp.encode(body.uncles))

  PortalBlockBodyLegacy(transactions: transactions, uncles: uncles)

func fromBlockBody*(T: type PortalBlockBodyShanghai, body: BlockBody): T =
  var transactions: Transactions
  for tx in body.transactions:
    discard transactions.add(TransactionByteList(rlp.encode(tx)))

  let uncles = Uncles(rlp.encode(body.uncles))

  doAssert(body.withdrawals.isSome())

  var withdrawals: Withdrawals
  for w in body.withdrawals.get():
    discard withdrawals.add(WithdrawalByteList(rlp.encode(w)))
  PortalBlockBodyShanghai(
    transactions: transactions, uncles: uncles, withdrawals: withdrawals
  )

func fromReceipts*(T: type PortalReceipts, receipts: seq[Receipt]): T =
  var portalReceipts: PortalReceipts
  for receipt in receipts:
    discard portalReceipts.add(ReceiptByteList(rlp.encode(receipt)))

  portalReceipts

## Calls to encode EL types to the SSZ encoded Portal types.

func encode*(blockBody: BlockBody): seq[byte] =
  if blockBody.withdrawals.isSome():
    SSZ.encode(PortalBlockBodyShanghai.fromBlockBody(blockBody))
  else:
    SSZ.encode(PortalBlockBodyLegacy.fromBlockBody(blockBody))

func encode*(receipts: seq[Receipt]): seq[byte] =
  let portalReceipts = PortalReceipts.fromReceipts(receipts)

  SSZ.encode(portalReceipts)

## RLP writer append calls for the Portal/SSZ types

template append*(w: var RlpWriter, v: TransactionByteList) =
  w.appendRawBytes(v.asSeq)

template append*(w: var RlpWriter, v: WithdrawalByteList) =
  w.appendRawBytes(v.asSeq)

template append*(w: var RlpWriter, v: ReceiptByteList) =
  w.appendRawBytes(v.asSeq)
