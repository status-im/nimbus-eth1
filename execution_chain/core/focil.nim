# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[typetraits, sets, tables],
  eth/rlp,
  eth/common/[transactions_rlp, blocks],
  chronicles,
  ../db/ledger,
  ./tx_pool/tx_item

from ../transaction import recoverSenderCached
from ../utils/utils import short
from ./validate import gasCost
from ./pooled_txs import PooledTransaction
from web3/engine_api_types import TypedTransaction

type
  DecodedILItem* = object
    tx*: Transaction
    ok*: bool
    hash*: Hash32

  DecodedIL* = ref object
    list*: seq[DecodedILItem]

proc decodeIL*(list: openArray[TypedTransaction]): DecodedIL =
  let res = DecodedIL()
  for x in list:
    try:
      res.list.add DecodedILItem(
        tx: rlp.decode(distinctBase(x), Transaction),
        ok: true,
        hash: keccak256(distinctBase(x)),
      )
    except RlpError:
      res.list.add DecodedILItem(
        ok: false,
        hash: keccak256(distinctBase(x)),
      )
  res

func missingHashes(list: HashSet[Hash32]): string =
  var
    log: seq[string]
  for x in list:
    log.add x.short
    if log.len >= 5:
      break
  $log

# ValidateInclusionListTransactions verifies that all transactions in the inclusion list
# are either included in the block or cannot be appended at the end of the block.
# Returns true if the block satisfies the inclusion list constraints.
proc validateInclusionList*(ledger: LedgerRef, decodedIL: DecodedIL, blk: Block): bool =
  # Build a set of transaction hashes that are included in the block
  var includedTxs: HashSet[Hash32]
  for tx in blk.transactions:
    includedTxs.incl tx.computeRlpHash

  template header: auto = blk.header

  let
    gasLeft = header.gasLimit - header.gasUsed

  # Statistics for logging
  var
    alreadyIncluded:   int
    blobTxs:           int
    insufficientGas:   int
    invalidSender:     int
    insufficientFunds: int
    invalidNonce:      int
    shouldBeIncluded:  HashSet[Hash32]

  # Check each inclusion list transaction
  for item in decodedIL.list:
    # Transaction is included - constraint satisfied
    if item.hash in includedTxs:
      inc alreadyIncluded
      continue

    if not item.ok:
      continue

    # Blob transactions are not subject to inclusion list constraints
    if item.tx.txType == TxEip4844:
      inc blobTxs
      continue

    # Check if transaction cannot be included due to gas limit
    if item.tx.gasLimit > gasLeft:
      inc insufficientGas
      continue

    # Check sender validity
    let sender = item.tx.recoverSenderCached().valueOr:
      inc invalidSender
      continue

    # Check if transaction cannot be included due to insufficient balance
    let
      balance = ledger.getBalance(sender)
      cost = item.tx.gasCost()

    if balance - cost < item.tx.value:
      inc insufficientFunds
      continue

    # Check if transaction cannot be included due to incorrect nonce
    let nonce = ledger.getNonce(sender)
    if nonce != item.tx.nonce:
      inc invalidNonce
      continue

    # Transaction could have been included but wasn't - validation fails
    shouldBeIncluded.incl item.hash

  if shouldBeIncluded.len > 0:
    warn "[FOCIL] Inclusion list validation failed - transactions should have been included",
      blockNumber=header.number,
      hash=computeRlpHash(header).short,
      missingHashes=missingHashes(shouldBeIncluded),
      alreadyIncluded,
      blobTxs,
      insufficientGas,
      invalidSender,
      insufficientFunds,
      invalidNonce,
      shouldBeIncluded=shouldBeIncluded.len,
      gasLeft,
      totalInclusionList=decodedIL.list.len,
      blockTxs=blk.transactions.len
    return false

  # All transactions are either included or cannot be included
  if decodedIL.list.len > 0:
    debug "[FOCIL] Inclusion list validation passed",
      blockNumber=header.number,
      hash=computeRlpHash(header).short,
      alreadyIncluded,
      blobTxs,
      insufficientGas,
      invalidSender,
      insufficientFunds,
      invalidNonce,
      totalInclusionList=decodedIL.list.len
  true

type
  Focil* = ref object
    list*: Table[Hash32, TxItemRef]

proc toTxItem(tx: Transaction): Result[TxItemRef, string] =
  let sender = tx.recoverSenderCached().valueOr:
    return err("[toTxItem] cannot recover sender")

  ok(TxItemRef.new(
    PooledTransaction(tx: tx),
    tx.computeRlpHash(),
    sender
  ))

proc toFocil*(list: openArray[TypedTransaction]): Result[Focil, string] =
  var focil = Focil()
  try:
    for x in list:
      let item = ? toTxItem(rlp.decode(distinctBase(x), Transaction))
      focil.list[item.id] = item
    ok(focil)
  except RlpError as exc:
    warn "[toFocil] failed to decode Inclusion List transaction",
      msg = exc.msg
    err(exc.msg)
