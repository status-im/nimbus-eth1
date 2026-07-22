# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  std/json,
  ../common/common,
  stew/byteutils,
  ../evm/state,
  ../evm/types,
  ../db/ledger,
  ../core/pooled_txs,
  ./utils,
  ./state_dump

func `$`(bloom: Bloom): string =
  bloom.toHex

func `$`(nonce: Bytes8): string =
  nonce.toHex

func `$`(data: seq[byte]): string =
  if data.len == 0:
    return "zero length"
  data.toHex

func `$`[T](x: Opt[T]): string =
  if x.isSome:
    $x.value
  else:
    "none"

func debug*(h: Header): string =
  var res: string
  res.add "parentHash     : " & $h.parentHash   & "\n"
  res.add "ommersHash     : " & $h.ommersHash   & "\n"
  res.add "coinbase       : " & $h.coinbase     & "\n"
  res.add "stateRoot      : " & $h.stateRoot    & "\n"
  res.add "txRoot         : " & $h.txRoot       & "\n"
  res.add "receiptsRoot   : " & $h.receiptsRoot & "\n"
  res.add "logsBloom      : " & $h.logsBloom    & "\n"
  res.add "difficulty     : " & $h.difficulty   & "\n"
  res.add "number         : " & $h.number       & "\n"
  res.add "gasLimit       : " & $h.gasLimit     & "\n"
  res.add "gasUsed        : " & $h.gasUsed      & "\n"
  res.add "timestamp      : " & $h.timestamp    & "\n"
  res.add "extraData      : " & $h.extraData    & "\n"
  res.add "mixHash        : " & $h.mixHash      & "\n"
  res.add "nonce          : " & $h.nonce        & "\n"
  res.add "baseFeePerGas  : " & $h.baseFeePerGas   & "\n"
  res.add "withdrawalsRoot: " & $h.withdrawalsRoot & "\n"
  res.add "blobGasUsed    : " & $h.blobGasUsed     & "\n"
  res.add "excessBlobGas  : " & $h.excessBlobGas   & "\n"
  res.add "beaconRoot     : " & $h.parentBeaconBlockRoot & "\n"
  res.add "requestsHash   : " & $h.requestsHash    & "\n"
  res.add "blockAccessListHash:" & $h.blockAccessListHash & "\n"
  res.add "slotNumber     : " & $h.slotNumber      & "\n"
  res.add "blockHash      : " & $computeBlockHash(h) & "\n"
  res

proc dumpAccounts*(vmState: BaseVMState): JsonNode =
  %dumpAccounts(vmState.ledger)

proc debugAccounts*(
    ledger: LedgerRef, addresses: openArray[string]): string {.raises: [ValueError].} =
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
  var res: string
  res.add "proofOfStake     : " & $vms.proofOfStake        & "\n"
  res.add "parent           : " & $vms.parent.computeBlockHash    & "\n"
  res.add "timestamp        : " & $vms.blockCtx.timestamp  & "\n"
  res.add "gasLimit         : " & $vms.blockCtx.gasLimit   & "\n"
  res.add "baseFeePerGas    : " & $vms.blockCtx.baseFeePerGas & "\n"
  res.add "prevRandao       : " & $vms.blockCtx.prevRandao & "\n"
  res.add "blockDifficulty  : " & $vms.blockCtx.difficulty & "\n"
  res.add "coinbase         : " & $vms.blockCtx.coinbase   & "\n"
  res.add "excessBlobGas    : " & $vms.blockCtx.excessBlobGas & "\n"
  res.add "parentHash       : " & $vms.blockCtx.parentHash & "\n"
  res.add "slotNumber       : " & $vms.blockCtx.slotNumber & "\n"
  res.add "flags            : " & $vms.flags               & "\n"
  res.add "receipts.len     : " & $vms.receipts.len        & "\n"
  res.add "ledger.root      : " & $vms.ledger.getStateRoot() & "\n"
  res.add "cumulativeGasUsed: " & $vms.cumulativeGasUsed   & "\n"
  res.add "tx.origin        : " & $vms.txCtx.origin        & "\n"
  res.add "tx.gasPrice      : " & $vms.txCtx.gasPrice      & "\n"
  res.add "tx.blobHash.len  : " & $vms.txCtx.versionedHashes.len & "\n"
  res.add "tx.blobBaseFee   : " & $vms.txCtx.blobBaseFee   & "\n"
  res.add "fork             : " & $vms.fork                & "\n"
  res

func `$`(acl: transactions.AccessList): string =
  if acl.len == 0:
    return "zero length"

  var res: string
  if acl.len > 0:
    res.add "\n"

  for ap in acl:
    res.add " * " & $ap.address & "\n"
    for i, k in ap.storageKeys:
      res.add "   - " & k.toHex
      if i < ap.storageKeys.len - 1:
        res.add "\n"
  res

func debug*(tx: Transaction): string =
  var res: string
  res.add "txType        : " & $tx.txType         & "\n"
  res.add "chainId       : " & $tx.chainId        & "\n"
  res.add "nonce         : " & $tx.nonce          & "\n"
  res.add "gasPrice      : " & $tx.gasPrice       & "\n"
  res.add "maxPriorityFee: " & $tx.maxPriorityFeePerGas & "\n"
  res.add "maxFee        : " & $tx.maxFeePerGas         & "\n"
  res.add "gasLimit      : " & $tx.gasLimit       & "\n"
  res.add "to            : " & $tx.to             & "\n"
  res.add "value         : " & $tx.value          & "\n"
  res.add "payload       : " & $tx.payload        & "\n"
  res.add "accessList    : " & $tx.accessList     & "\n"
  res.add "maxFeePerBlobGas: " & $tx.maxFeePerBlobGas & "\n"
  res.add "versionedHashes.len: " & $tx.versionedHashes.len & "\n"
  res.add "V             : " & $tx.V              & "\n"
  res.add "R             : " & $tx.R              & "\n"
  res.add "S             : " & $tx.S              & "\n"
  res

func debug*(tx: PooledTransaction): string =
  var res: string
  res.add debug(tx.tx)
  if tx.blobsBundle.isNil:
    res.add "networkPaylod : nil\n"
  else:
    res.add "networkPaylod : \n"
    res.add " - blobs       : " & $tx.blobsBundle.blobs.len & "\n"
    res.add " - commitments : " & $tx.blobsBundle.commitments.len & "\n"
    res.add " - proofs      : " & $tx.blobsBundle.proofs.len & "\n"
  res

func debugSum*(h: Header): string =
  var res: string
  res.add "txRoot         : " & $h.txRoot      & "\n"
  res.add "ommersHash     : " & $h.ommersHash  & "\n"
  h.withdrawalsRoot.isErrOr:
    res.add "withdrawalsRoot: " & $value & "\n"
  res.add "sumHash        : " & $sumHash(h)   & "\n"
  res

func debugSum*(body: BlockBody): string =
  let ommersHash = keccak256(rlp.encode(body.uncles))
  let txRoot = calcTxRoot(body.transactions)
  let wdRoot = if body.withdrawals.isSome:
                 calcWithdrawalsRoot(body.withdrawals.get)
               else: EMPTY_ROOT_HASH
  let numwd = if body.withdrawals.isSome:
                $body.withdrawals.get().len
              else:
                "none"
  var res: string
  res.add "txRoot     : " & $txRoot        & "\n"
  res.add "ommersHash : " & $ommersHash    & "\n"
  body.withdrawals.isErrOr:
    res.add "wdRoot     : " & $wdRoot      & "\n"
  res.add "num tx     : " & $body.transactions.len & "\n"
  res.add "num uncles : " & $body.uncles.len & "\n"
  res.add "num wd     : " & numwd          & "\n"
  res.add "sumHash    : " & $sumHash(body) & "\n"
  res
