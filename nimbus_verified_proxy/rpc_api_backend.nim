# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import json_rpc/[rpcproxy, rpcclient], web3/[eth_api, eth_api_types], stint, ./types

proc initNetworkApiBackend*(vp: VerifiedRpcProxy): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[UInt256] {.async.} =
      await vp.proxy.getClient.eth_chainId()

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getBlockByHash(blkHash, fullTransactions)

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getBlockByNumber(blkNum, fullTransactions)

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getProof(address, slots, blockId)

    createAccessListProc = proc(
        args: TransactionArgs, blockId: BlockTag
    ): Future[AccessListResult] {.async: (raw: true).} =
      vp.proxy.getClient.eth_createAccessList(args, blockId)

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[seq[byte]] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getCode(address, blockId)

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[TransactionObject] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getTransactionByHash(txHash)

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[ReceiptObject] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getTransactionReceipt(txHash)

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[seq[ReceiptObject]] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getBlockReceipts(blockId)

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[seq[LogObject]] {.async: (raw: true).} =
      vp.proxy.getClient.eth_getLogs(filterOptions)

  EthApiBackend(
    eth_chainId: ethChainIdProc,
    eth_getBlockByHash: getBlockByHashProc,
    eth_getBlockByNumber: getBlockByNumberProc,
    eth_getProof: getProofProc,
    eth_createAccessList: createAccessListProc,
    eth_getCode: getCodeProc,
    eth_getBlockReceipts: getBlockReceiptsProc,
    eth_getLogs: getLogsProc,
    eth_getTransactionByHash: getTransactionByHashProc,
    eth_getTransactionReceipt: getTransactionReceiptProc,
  )
