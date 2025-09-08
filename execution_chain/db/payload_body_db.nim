# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push gcsafe, raises: [].}

import
  chronicles,
  web3/engine_api_types,
  eth/common/blocks_rlp,
  eth/common/hashes,
  ./core_db/base,
  ./core_db/core_apps,
  ./storage_types,
  ../constants,
  ../beacon/web3_eth_conv

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template wrapRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    return err(info & ": " & e.msg)

proc read(rlp: var Rlp, T: type Quantity): T {.raises: [RlpError].} =
  rlp.read(uint64).Quantity

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getExecutionPayloadBodyV1*(
    db: CoreDbTxRef;
    header: Header;
      ): Result[ExecutionPayloadBodyV1, string] =
  const info = "getExecutionPayloadBodyV1()"
  var body: ExecutionPayloadBodyV1

  for encodedTx in db.getBlockTransactionData(header.txRoot):
    body.transactions.add TypedTransaction(encodedTx)

  # Txs not there in db - Happens during era1/era import, when we don't store txs and receipts
  if (body.transactions.len == 0 and header.txRoot != zeroHash32):
    return err("No transactions found in db for txRoot " & $header.txRoot)

  if header.withdrawalsRoot.isSome:
    let withdrawalsRoot = header.withdrawalsRoot.value
    if withdrawalsRoot == emptyRoot:
      var wds: seq[WithdrawalV1]
      body.withdrawals = Opt.some(wds)
      return ok(move(body))

    wrapRlpException info:
      let bytes = db.get(withdrawalsKey(withdrawalsRoot).toOpenArray).valueOr:
        if error.error != KvtNotFound:
          warn info, withdrawalsRoot, error=($$error)
        else:
          # Fallback to old withdrawals format
          var wds: seq[WithdrawalV1]
          for wd in db.getWithdrawals(WithdrawalV1, withdrawalsRoot):
            wds.add(wd)
          body.withdrawals = Opt.some(wds)
        return ok(move(body))

      var list = rlp.decode(bytes, seq[WithdrawalV1])
      body.withdrawals = Opt.some(move(list))

  ok(move(body))

func toPayloadBody*(blk: Block): ExecutionPayloadBodyV1 =
  var wds: seq[WithdrawalV1]
  if blk.withdrawals.isSome:
    for w in blk.withdrawals.get:
      wds.add w3Withdrawal(w)

  ExecutionPayloadBodyV1(
    transactions: w3Txs(blk.transactions),
    # pre Shanghai block return null withdrawals
    # post Shanghai block return at least empty slice
    withdrawals: if blk.withdrawals.isSome:
                   Opt.some(wds)
                 else:
                   Opt.none(seq[WithdrawalV1])
  )
