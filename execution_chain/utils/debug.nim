# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[options, json],
  ../common/common,
  stew/byteutils,
  ../evm/state,
  ../evm/types,
  ../db/ledger,
  ../core/pooled_txs,
  ./utils,
  ./state_dump

proc `$`(bloom: Bloom): string =
  bloom.toHex

proc `$`(nonce: Bytes8): string =
  nonce.toHex

proc `$`(data: seq[byte]): string =
  if data.len == 0:
    return "zero length"
  data.toHex

proc debug*(h: Header): string =
  result.add "parentHash     : " & $h.parentHash   & "\n"
  result.add "ommersHash     : " & $h.ommersHash   & "\n"
  result.add "coinbase       : " & $h.coinbase     & "\n"
  result.add "stateRoot      : " & $h.stateRoot    & "\n"
  result.add "txRoot         : " & $h.txRoot       & "\n"
  result.add "receiptsRoot   : " & $h.receiptsRoot & "\n"
  result.add "logsBloom      : " & $h.logsBloom    & "\n"
  result.add "difficulty     : " & $h.difficulty   & "\n"
  result.add "blockNumber    : " & $h.number       & "\n"
  result.add "gasLimit       : " & $h.gasLimit     & "\n"
  result.add "gasUsed        : " & $h.gasUsed      & "\n"
  result.add "timestamp      : " & $h.timestamp    & "\n"
  result.add "extraData      : " & $h.extraData    & "\n"
  result.add "mixHash        : " & $h.mixHash      & "\n"
  result.add "nonce          : " & $h.nonce        & "\n"
  result.add "baseFeePerGas.isSome: " & $h.baseFeePerGas.isSome  & "\n"
  if h.baseFeePerGas.isSome:
    result.add "baseFeePerGas  : " & $h.baseFeePerGas.get()   & "\n"
  if h.withdrawalsRoot.isSome:
    result.add "withdrawalsRoot: " & $h.withdrawalsRoot.get() & "\n"
  if h.blobGasUsed.isSome:
    result.add "blobGasUsed    : " & $h.blobGasUsed.get() & "\n"
  if h.excessBlobGas.isSome:
    result.add "excessBlobGas  : " & $h.excessBlobGas.get() & "\n"
  if h.parentBeaconBlockRoot.isSome:
    result.add "beaconRoot     : " & $h.parentBeaconBlockRoot.get() & "\n"
  if h.requestsHash.isSome:
    result.add "requestsHash   : " & $h.requestsHash.get() & "\n"
  result.add "blockHash      : " & $computeBlockHash(h) & "\n"

proc dumpAccounts*(vmState: BaseVMState): JsonNode =
  %dumpAccounts(vmState.ledger)

proc debugAccounts*(ledger: LedgerRef, addresses: openArray[string]): string =
  var accountList = newSeq[Address]()
  for address in addresses:
    accountList.add Address.fromHex(address)

  (%dumpAccounts(ledger, accountList)).pretty

proc debugAccounts*(vmState: BaseVMState): string =
  var accountList = newSeq[Address]()
  for address in vmState.ledger.addresses:
    accountList.add address

  let res = %{
    "stateRoot": %($vmState.readOnlyLedger.getStateRoot()),
    "accounts": %dumpAccounts(vmState.ledger, accountList),
  }

  res.pretty

proc debug*(vms: BaseVMState): string =
  result.add "proofOfStake     : " & $vms.proofOfStake()      & "\n"
  result.add "parent           : " & $vms.parent.computeBlockHash    & "\n"
  result.add "timestamp        : " & $vms.blockCtx.timestamp  & "\n"
  result.add "gasLimit         : " & $vms.blockCtx.gasLimit   & "\n"
  result.add "baseFeePerGas    : " & $vms.blockCtx.baseFeePerGas & "\n"
  result.add "prevRandao       : " & $vms.blockCtx.prevRandao & "\n"
  result.add "blockDifficulty  : " & $vms.blockCtx.difficulty & "\n"
  result.add "coinbase         : " & $vms.blockCtx.coinbase   & "\n"
  result.add "excessBlobGas    : " & $vms.blockCtx.excessBlobGas & "\n"
  result.add "flags            : " & $vms.flags               & "\n"
  result.add "receipts.len     : " & $vms.receipts.len        & "\n"
  result.add "ledger.root     : " & $vms.ledger.getStateRoot() & "\n"
  result.add "cumulativeGasUsed: " & $vms.cumulativeGasUsed   & "\n"
  result.add "tx.origin        : " & $vms.txCtx.origin        & "\n"
  result.add "tx.gasPrice      : " & $vms.txCtx.gasPrice      & "\n"
  result.add "tx.blobHash.len  : " & $vms.txCtx.versionedHashes.len & "\n"
  result.add "tx.blobBaseFee   : " & $vms.txCtx.blobBaseFee   & "\n"
  result.add "fork             : " & $vms.fork                & "\n"

proc `$`(acl: transactions.AccessList): string =
  if acl.len == 0:
    return "zero length"

  if acl.len > 0:
    result.add "\n"

  for ap in acl:
    result.add " * " & $ap.address & "\n"
    for i, k in ap.storageKeys:
      result.add "   - " & k.toHex
      if i < ap.storageKeys.len-1:
        result.add "\n"

proc debug*(tx: Transaction): string =
  result.add "txType        : " & $tx.txType         & "\n"
  result.add "chainId       : " & $tx.chainId        & "\n"
  result.add "nonce         : " & $tx.nonce          & "\n"
  result.add "gasPrice      : " & $tx.gasPrice       & "\n"
  result.add "maxPriorityFee: " & $tx.maxPriorityFeePerGas & "\n"
  result.add "maxFee        : " & $tx.maxFeePerGas         & "\n"
  result.add "gasLimit      : " & $tx.gasLimit       & "\n"
  result.add "to            : " & $tx.to             & "\n"
  result.add "value         : " & $tx.value          & "\n"
  result.add "payload       : " & $tx.payload        & "\n"
  result.add "accessList    : " & $tx.accessList     & "\n"
  result.add "maxFeePerBlobGas: " & $tx.maxFeePerBlobGas & "\n"
  result.add "versionedHashes.len: " & $tx.versionedHashes.len & "\n"
  result.add "V             : " & $tx.V              & "\n"
  result.add "R             : " & $tx.R              & "\n"
  result.add "S             : " & $tx.S              & "\n"

proc debug*(tx: PooledTransaction): string =
  result.add debug(tx.tx)
  if tx.blobsBundle.isNil:
    result.add "networkPaylod : nil\n"
  else:
    result.add "networkPaylod : \n"
    result.add " - blobs       : " & $tx.blobsBundle.blobs.len & "\n"
    result.add " - commitments : " & $tx.blobsBundle.commitments.len & "\n"
    result.add " - proofs      : " & $tx.blobsBundle.proofs.len & "\n"

proc debugSum*(h: Header): string =
  result.add "txRoot         : " & $h.txRoot      & "\n"
  result.add "ommersHash     : " & $h.ommersHash  & "\n"
  if h.withdrawalsRoot.isSome:
    result.add "withdrawalsRoot: " & $h.withdrawalsRoot.get() & "\n"
  result.add "sumHash        : " & $sumHash(h)   & "\n"

proc debugSum*(body: BlockBody): string =
  let ommersHash = keccak256(rlp.encode(body.uncles))
  let txRoot = calcTxRoot(body.transactions)
  let wdRoot = if body.withdrawals.isSome:
                 calcWithdrawalsRoot(body.withdrawals.get)
               else: EMPTY_ROOT_HASH
  let numwd = if body.withdrawals.isSome:
                $body.withdrawals.get().len
              else:
                "none"
  result.add "txRoot     : " & $txRoot        & "\n"
  result.add "ommersHash : " & $ommersHash    & "\n"
  if body.withdrawals.isSome:
    result.add "wdRoot     : " & $wdRoot      & "\n"
  result.add "num tx     : " & $body.transactions.len & "\n"
  result.add "num uncles : " & $body.uncles.len & "\n"
  result.add "num wd     : " & numwd          & "\n"
  result.add "sumHash    : " & $sumHash(body) & "\n"
