# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Item Container & Wrapper
## =========================================
##

import
  std/[hashes, times],
  ../../utils/ec_recover,
  ../../utils/utils,
  ../../transaction,
  ./tx_info,
  eth/common/transaction_utils,
  results

from eth/common/eth_types_rlp import rlpHash

{.push raises: [].}

type
  TxItemStatus* = enum ##\
    ## Current status of a transaction as seen by the pool.
    txItemPending = 0
    txItemStaged
    txItemPacked

  TxItemRef* = ref object of RootObj ##\
    ## Data container with transaction and meta data. Entries are *read-only*\
    ## by default, for some there is a setter available.
    tx:        PooledTransaction     ## Transaction data
    itemID:    Hash32               ## Transaction hash
    timeStamp: Time                  ## Time when added
    sender:    Address            ## Sender account address
    info:      string                ## Whatever
    status:    TxItemStatus          ## Transaction status (setter available)
    reject:    TxInfo                ## Reason for moving to waste basket

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc utcTime: Time =
  getTime().utc.toTime

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------

proc init*(item: TxItemRef; status: TxItemStatus; info: string) =
  ## Update item descriptor.
  item.info = info
  item.status = status
  item.timeStamp = utcTime()
  item.reject = txInfoOk

proc new*(T: type TxItemRef; tx: PooledTransaction; itemID: Hash32;
          status: TxItemStatus; info: string): Result[T,void] {.gcsafe,raises: [].} =
  ## Create item descriptor.
  let rc = tx.tx.recoverSender()
  if rc.isErr:
    return err()
  ok(T(itemID:    itemID,
       tx:        tx,
       sender:    rc.value,
       timeStamp: utcTime(),
       info:      info,
       status:    status))

proc new*(T: type TxItemRef; tx: PooledTransaction;
          reject: TxInfo; status: TxItemStatus; info: string): T {.gcsafe,raises: [].} =
  ## Create incomplete item descriptor, so meta-data can be stored (e.g.
  ## for holding in the waste basket to be investigated later.)
  T(tx:        tx,
    timeStamp: utcTime(),
    info:      info,
    status:    status)

# ------------------------------------------------------------------------------
#  Public functions, Table ID helper
# ------------------------------------------------------------------------------

proc hash*(item: TxItemRef): Hash =
  ## Needed if `TxItemRef` is used as hash-`Table` index.
  cast[pointer](item).hash

# ------------------------------------------------------------------------------
# Public functions, transaction getters
# ------------------------------------------------------------------------------

proc itemID*(tx: Transaction): Hash32 =
  ## Getter, transaction ID
  tx.rlpHash

proc itemID*(tx: PooledTransaction): Hash32 =
  ## Getter, transaction ID
  tx.rlpHash

# core/types/transaction.go(297): func (tx *Transaction) Cost() *big.Int {
proc cost*(tx: Transaction): UInt256 =
  ## Getter (go/ref compat): gas * gasPrice + value.
  (tx.gasPrice * tx.gasLimit).u256 + tx.value

func effectiveGasTip*(tx: Transaction; baseFee: GasInt): GasInt =
  effectiveGasTip(tx, Opt.some(baseFee.u256))

# ------------------------------------------------------------------------------
# Public functions, item getters
# ------------------------------------------------------------------------------

proc dup*(item: TxItemRef): TxItemRef =
  ## Getter, provide contents copy
  TxItemRef(
    tx: item.tx,
    itemID: item.itemID,
    timeStamp: item.timeStamp,
    sender: item.sender,
    info: item.info,
    status: item.status,
    reject: item.reject
  )

proc info*(item: TxItemRef): string =
  ## Getter
  item.info

proc itemID*(item: TxItemRef): Hash32 =
  ## Getter
  item.itemID

proc reject*(item: TxItemRef): TxInfo =
  ## Getter
  item.reject

proc sender*(item: TxItemRef): Address =
  ## Getter
  item.sender

proc status*(item: TxItemRef): TxItemStatus =
  ## Getter
  item.status

proc timeStamp*(item: TxItemRef): Time =
  ## Getter
  item.timeStamp

proc pooledTx*(item: TxItemRef): PooledTransaction =
  ## Getter
  item.tx

proc tx*(item: TxItemRef): Transaction =
  ## Getter
  item.tx.tx

func rejectInfo*(item: TxItemRef): string =
  ## Getter
  result = $item.reject
  if item.info.len > 0:
    result.add ": "
    result.add item.info

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `status=`*(item: TxItemRef; val: TxItemStatus) =
  ## Setter
  item.status = val

proc `reject=`*(item: TxItemRef; val: TxInfo) =
  ## Setter
  item.reject = val

proc `info=`*(item: TxItemRef; val: string) =
  ## Setter
  item.info = val

# ------------------------------------------------------------------------------
# Public functions, pretty printing and debugging
# ------------------------------------------------------------------------------

proc `$`*(w: TxItemRef): string =
  ## Visualise item ID (use for debugging)
  "<" & w.itemID.short & ">"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
