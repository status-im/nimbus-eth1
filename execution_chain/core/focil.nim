# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[typetraits, tables],
  eth/common/[transactions_rlp],
  chronicles,
  ./tx_pool/tx_item

from ../transaction import recoverSenderCached
from ./pooled_txs import PooledTransaction
from web3/engine_api_types import TypedTransaction

type
  Focil* = ref object
    list*: Table[Hash32, TxItemRef]

proc toTxItem(tx: Transaction): Result[TxItemRef, string] =
  let
    sender = tx.recoverSenderCached().valueOr:
      return err("[toTxItem] cannot recover sender")
    (size, id) = getEncodedLengthAndHash(tx)

  ok(TxItemRef.new(
    PooledTransaction(tx: tx),
    id,
    sender,
    size.uint64
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
