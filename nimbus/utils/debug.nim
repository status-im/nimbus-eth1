# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[options, times, json, strutils],
  ../common/common,
  stew/byteutils,
  ../vm_state,
  ../vm_types,
  ../db/ledger,
  ./utils

proc `$`(hash: Hash256): string =
  hash.data.toHex

proc `$`(bloom: BloomFilter): string =
  bloom.toHex

proc `$`(nonce: BlockNonce): string =
  nonce.toHex

proc `$`(data: Blob): string =
  if data.len == 0:
    return "zero length"
  data.toHex

proc debug*(h: BlockHeader): string =
  result.add "parentHash     : " & $h.parentHash  & "\n"
  result.add "ommersHash     : " & $h.ommersHash  & "\n"
  result.add "coinbase       : " & $h.coinbase    & "\n"
  result.add "stateRoot      : " & $h.stateRoot   & "\n"
  result.add "txRoot         : " & $h.txRoot      & "\n"
  result.add "receiptRoot    : " & $h.receiptRoot & "\n"
  result.add "bloom          : " & $h.bloom       & "\n"
  result.add "difficulty     : " & $h.difficulty  & "\n"
  result.add "blockNumber    : " & $h.blockNumber & "\n"
  result.add "gasLimit       : " & $h.gasLimit    & "\n"
  result.add "gasUsed        : " & $h.gasUsed     & "\n"
  result.add "timestamp      : " & $h.timestamp.toUnix   & "\n"
  result.add "extraData      : " & $h.extraData   & "\n"
  result.add "mixDigest      : " & $h.mixDigest   & "\n"
  result.add "nonce          : " & $h.nonce       & "\n"
  result.add "fee.isSome     : " & $h.fee.isSome  & "\n"
  if h.fee.isSome:
    result.add "fee            : " & $h.fee.get()   & "\n"
  if h.withdrawalsRoot.isSome:
    result.add "withdrawalsRoot: " & $h.withdrawalsRoot.get() & "\n"
  if h.blobGasUsed.isSome:
    result.add "blobGasUsed    : " & $h.blobGasUsed.get() & "\n"
  if h.excessBlobGas.isSome:
    result.add "excessBlobGas  : " & $h.excessBlobGas.get() & "\n"
  result.add "blockHash      : " & $blockHash(h) & "\n"

proc dumpAccount(stateDB: LedgerRef, address: EthAddress): JsonNode =
  var storage = newJObject()
  for k, v in stateDB.cachedStorage(address):
    storage[k.toHex] = %v.toHex

  result = %{
    "nonce": %toHex(stateDB.getNonce(address)),
    "balance": %stateDB.getBalance(address).toHex(),
    "codehash": %($stateDB.getCodeHash(address)),
    "storageRoot": %($stateDB.getStorageRoot(address)),
    "storage": storage
  }

proc dumpAccounts*(vmState: BaseVMState): JsonNode =
  result = newJObject()
  for ac in vmState.stateDB.addresses:
    result[ac.toHex] = dumpAccount(vmState.stateDB, ac)

proc debugAccounts*(vmState: BaseVMState): string =
  var
    accounts = newJObject()
    accountList = newSeq[EthAddress]()

  for address in vmState.stateDB.addresses:
    accountList.add address

  for i, ac in accountList:
    accounts[ac.toHex] = dumpAccount(vmState.stateDB, ac)

  let res = %{
    "rootHash": %($vmState.readOnlyStateDB.rootHash),
    "accounts": accounts
  }

  res.pretty

proc debug*(vms: BaseVMState): string =
  result.add "com.consensus    : " & $vms.com.consensus       & "\n"
  result.add "parent           : " & $vms.parent.blockHash    & "\n"
  result.add "timestamp        : " & $vms.blockCtx.timestamp.toUnix & "\n"
  result.add "gasLimit         : " & $vms.blockCtx.gasLimit   & "\n"
  result.add "fee              : " & $vms.blockCtx.fee        & "\n"
  result.add "prevRandao       : " & $vms.blockCtx.prevRandao & "\n"
  result.add "blockDifficulty  : " & $vms.blockCtx.difficulty & "\n"
  result.add "coinbase         : " & $vms.blockCtx.coinbase   & "\n"
  result.add "excessBlobGas    : " & $vms.blockCtx.excessBlobGas & "\n"
  result.add "flags            : " & $vms.flags               & "\n"
  result.add "receipts.len     : " & $vms.receipts.len        & "\n"
  result.add "stateDB.root     : " & $vms.stateDB.rootHash    & "\n"
  result.add "cumulativeGasUsed: " & $vms.cumulativeGasUsed   & "\n"
  result.add "tx.origin        : " & $vms.txCtx.origin        & "\n"
  result.add "tx.gasPrice      : " & $vms.txCtx.gasPrice      & "\n"
  result.add "tx.blobHash.len  : " & $vms.txCtx.versionedHashes.len & "\n"
  result.add "tx.blobBaseFee   : " & $vms.txCtx.blobBaseFee   & "\n"
  result.add "fork             : " & $vms.fork                & "\n"

proc `$`(x: ChainId): string =
  $int(x)

proc `$`(acl: AccessList): string =
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
  result.add "maxPriorityFee: " & $tx.maxPriorityFee & "\n"
  result.add "maxFee        : " & $tx.maxFee         & "\n"
  result.add "gasLimit      : " & $tx.gasLimit       & "\n"
  result.add "to            : " & $tx.to             & "\n"
  result.add "value         : " & $tx.value          & "\n"
  result.add "payload       : " & $tx.payload        & "\n"
  result.add "accessList    : " & $tx.accessList     & "\n"
  result.add "V             : " & $tx.V              & "\n"
  result.add "R             : " & $tx.R              & "\n"
  result.add "S             : " & $tx.S              & "\n"

proc debugSum*(h: BlockHeader): string =
  result.add "txRoot         : " & $h.txRoot      & "\n"
  result.add "ommersHash     : " & $h.ommersHash  & "\n"
  if h.withdrawalsRoot.isSome:
    result.add "withdrawalsRoot: " & $h.withdrawalsRoot.get() & "\n"
  result.add "sumHash        : " & $sumHash(h)   & "\n"

proc debugSum*(body: BlockBody): string =
  let ommersHash = keccakHash(rlp.encode(body.uncles))
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
