# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  results,
  chronicles,
  json_rpc/[rpcserver, rpcclient, rpcproxy],
  eth/common/accounts,
  eth/common/addresses,
  web3/[primitives, eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/common/common,
  ../../execution_chain/db/ledger,
  ../../execution_chain/transaction/call_evm,
  ../../execution_chain/[evm/types, evm/state],
  ../validate_proof,
  ../header_store,
  ../types,
  ./blocks,
  ./accounts,
  ./transactions,
  ./receipts,
  ./evm

logScope:
  topics = "verified_proxy"

template rpcClient*(vp: VerifiedRpcProxy): RpcClient =
  vp.proxy.getClient()

proc installEthApiHandlers*(vp: VerifiedRpcProxy) =
  vp.proxy.rpc("eth_chainId") do() -> UInt256:
    vp.chainId

  vp.proxy.rpc("eth_getBlockByNumber") do(
    blockTag: BlockTag, fullTransactions: bool
  ) -> BlockObject:
    (await vp.getBlockByTag(blockTag, fullTransactions)).valueOr:
      raise newException(ValueError, error)

  vp.proxy.rpc("eth_getBlockByHash") do(
    blockHash: Hash32, fullTransactions: bool
  ) -> BlockObject:
    (await vp.getBlockByHash(blockHash, fullTransactions)).valueOr:
      raise newException(ValueError, error)

  #  vp.proxy.rpc("eth_getUncleCountByBlockNumber") do(
  #    blockTag: BlockTag
  #  ) -> Quantity:
  #    let blk = (await vp.getBlockByTag(blockTag, false)).valueOr:
  #      raise newException(ValueError, error)
  #    return Quantity(blk.uncles.len())
  #
  #  vp.proxy.rpc("eth_getUncleCountByBlockHash") do(
  #    blockHash: Hash32
  #  ) -> Quantity:
  #    let blk = (await vp.getBlockByHash(blockHash, false)).valueOr:
  #      raise newException(ValueError, error)
  #    return Quantity(blk.uncles.len())
  #
  #  vp.proxy.rpc("eth_getBlockTransactionCountByNumber") do(
  #    blockTag: BlockTag
  #  ) -> Quantity:
  #    let blk = (await vp.getBlockByTag(blockTag, true)).valueOr:
  #      raise newException(ValueError, error)
  #    return Quantity(blk.transactions.len)
  #
  #  vp.proxy.rpc("eth_getBlockTransactionCountByHash") do(
  #    blockHash: Hash32
  #  ) -> Quantity:
  #    let blk = (await vp.getBlockByHash(blockHash, true)).valueOr:
  #      raise newException(ValueError, error)
  #    return Quantity(blk.transactions.len)
  vp.proxy.rpc("eth_getTransactionByBlockNumberAndIndex") do(
    blockTag: BlockTag, index: Quantity
  ) -> TransactionObject:
    let blk = (await vp.getBlockByTag(blockTag, true)).valueOr:
      raise newException(ValueError, error)
    if distinctBase(index) >= uint64(blk.transactions.len):
      raise newException(ValueError, "provided transaction index is outside bounds")
    let x = blk.transactions[distinctBase(index)]
    doAssert x.kind == tohTx
    return x.tx

  vp.proxy.rpc("eth_getTransactionByBlockHashAndIndex") do(
    blockHash: Hash32, index: Quantity
  ) -> TransactionObject:
    let blk = (await vp.getBlockByHash(blockHash, true)).valueOr:
      raise newException(ValueError, error)

    if distinctBase(index) >= uint64(blk.transactions.len):
      raise newException(ValueError, "provided transaction index is outside bounds")
    let x = blk.transactions[distinctBase(index)]
    doAssert x.kind == tohTx
    return x.tx

  vp.proxy.rpc("eth_getTransactionByHash") do(txHash: Hash32) -> TransactionObject:
    let tx =
      try:
        await vp.rpcClient.eth_getTransactionByHash(txHash)
      except CatchableError as e:
        raise newException(ValueError, e.msg)
    if tx.hash != txHash:
      raise newException(
        ValueError,
        "the downloaded transaction hash doesn't match the requested transaction hash",
      )

    if not checkTxHash(tx, txHash):
      raise
        newException(ValueError, "the transaction doesn't hash to the provided hash")

    return tx

  # TODO: this method should also support block hashes. For that, the client call should also suupport block hashes
  vp.proxy.rpc("eth_getBlockReceipts") do(blockTag: BlockTag) -> Opt[seq[ReceiptObject]]:
    let rxs = (await vp.getReceiptsByBlockTag(blockTag)).valueOr:
      raise newException(ValueError, error)
    return Opt.some(rxs)

  vp.proxy.rpc("eth_getTransactionReceipt") do(txHash: Hash32) -> ReceiptObject:
    let
      rx =
        try:
          await vp.rpcClient.eth_getTransactionReceipt(txHash)
        except CatchableError as e:
          raise newException(ValueError, e.msg)
      rxs = (await vp.getReceiptsByBlockHash(rx.blockHash)).valueOr:
        raise newException(ValueError, error)

    for r in rxs:
      if r.transactionHash == txHash:
        return r

    raise newException(ValueError, "receipt couldn't be verified")

  #  # eth_blockNumber - get latest tag from header store
  #  vp.proxy.rpc("eth_blockNumber") do() -> Quantity:
  #    # Returns the number of the most recent block seen by the light client.
  #    let hLatest = vp.headerStore.latest()
  #    if hLatest.isNone:
  #      raise newException(ValueError, "Syncing")
  #
  #    return Quantity(hLatest.get().number)
  vp.proxy.rpc("eth_getBalance") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> UInt256:
    let
      header = (await vp.getHeaderByTag(blockTag)).valueOr:
        raise newException(ValueError, error)
      account = (await vp.getAccount(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    account.balance

  vp.proxy.rpc("eth_getStorageAt") do(
    address: addresses.Address, slot: UInt256, blockTag: BlockTag
  ) -> FixedBytes[32]:
    let
      header = (await vp.getHeaderByTag(blockTag)).valueOr:
        raise newException(ValueError, error)

      storage = (await vp.getStorageAt(address, slot, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    FixedBytes[32](storage.toBytesBE)

  #  vp.proxy.rpc("eth_getTransactionCount") do(
  #    address: addresses.Address, blockTag: BlockTag
  #  ) -> Quantity:
  #    let
  #      header = (await vp.getHeaderByTag(blockTag)).valueOr:
  #        raise newException(ValueError, error)
  #
  #      account = (await vp.getAccount(address, header.number, header.stateRoot)).valueOr:
  #        raise newException(ValueError, error)
  #
  #    Quantity(account.nonce)
  vp.proxy.rpc("eth_getCode") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> seq[byte]:
    let header = (await vp.getHeaderByTag(blockTag)).valueOr:
      raise newException(ValueError, error)

    (await vp.getCode(address, header.number, header.stateRoot)).valueOr:
      raise newException(ValueError, error)

  vp.proxy.rpc("eth_call") do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> seq[byte]:
    if tx.to.isNone():
      raise newException(ValueError, "to address is required")

    if blockTag.kind == bidAlias:
      raise newException(ValueError, "tag not yet implemented")

    let
      header = (await vp.getHeaderByTag(blockTag)).valueOr:
        raise newException(ValueError, error)

      optimisticStateFetch = optimisticStateFetch.valueOr:
        true

    let callResult = (await vp.evm.call(header, tx, optimisticStateFetch)).valueOr:
      raise newException(ValueError, error)

    return callResult.output

  vp.proxy.rpc("eth_createAccessList") do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> AccessListResult:
    if tx.to.isNone():
      raise newException(ValueError, "to address is required")

    if blockTag.kind == bidAlias:
      raise newException(ValueError, "tag not yet implemented")

    let
      header = (await vp.getHeaderByTag(blockTag)).valueOr:
        raise newException(ValueError, error)

      optimisticStateFetch = optimisticStateFetch.valueOr:
        true

    let (accessList, error, gasUsed) = (
      await vp.evm.createAccessList(header, tx, optimisticStateFetch)
    ).valueOr:
      raise newException(ValueError, error)

    return
      AccessListResult(accessList: accessList, error: error, gasUsed: gasUsed.Quantity)

  #  vp.proxy.rpc("eth_estimateGas") do(
  #    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  #  ) -> Quantity:
  #    if tx.to.isNone():
  #      raise newException(ValueError, "to address is required")
  #
  #    if blockTag.kind == bidAlias:
  #      raise newException(ValueError, "tag not yet implemented")
  #
  #    let
  #      header = (await vp.getHeaderByTag(blockTag)).valueOr:
  #        raise newException(ValueError, error)
  #
  #      optimisticStateFetch = optimisticStateFetch.valueOr:
  #        true
  #
  #    let gasEstimate = (await vp.evm.estimateGas(header, tx, optimisticStateFetch)).valueOr:
  #      raise newException(ValueError, error)
  #
  #    return gasEstimate.Quantity
  #
  # TODO:
  # Following methods are forwarded directly to the web3 provider and therefore
  # are not validated in any way.
  vp.proxy.registerProxyMethod("net_version")
  vp.proxy.registerProxyMethod("eth_sendRawTransaction")
  vp.proxy.registerProxyMethod("eth_getTransactionReceipt")

# Used to be in eth1_monitor.nim; not sure why it was deleted,
# so I copied it here. --Adam
template awaitWithRetries*[T](
    lazyFutExpr: Future[T], retries = 3, timeout = 60.seconds
): untyped =
  const reqType = astToStr(lazyFutExpr)
  var
    retryDelayMs = 16000
    f: Future[T]
    attempts = 0

  while true:
    f = lazyFutExpr
    yield f or sleepAsync(timeout)
    if not f.finished:
      await cancelAndWait(f)
    elif f.failed:
      when not (f.error of CatchableError):
        static:
          doAssert false, "f.error not CatchableError"
      debug "Web3 request failed", req = reqType, err = f.error.msg
    else:
      break

    inc attempts
    if attempts >= retries:
      var errorMsg = reqType & " failed " & $retries & " times"
      if f.failed:
        errorMsg &= ". Last error: " & f.error.msg
      raise newException(ValueError, errorMsg)

    await sleepAsync(chronos.milliseconds(retryDelayMs))
    retryDelayMs *= 2

  read(f)

proc verifyChaindId*(vp: VerifiedRpcProxy): Future[void] {.async.} =
  let localId = vp.chainId

  # retry 2 times, if the data provider fails despite the re-tries, propagate
  # exception to the caller.
  let providerId =
    awaitWithRetries(vp.rpcClient.eth_chainId(), retries = 2, timeout = seconds(30))

  # This is a chain/network mismatch error between the Nimbus verified proxy and
  # the application using it. Fail fast to avoid misusage. The user must fix
  # the configuration.
  if localId != providerId:
    fatal "The specified data provider serves data for a different chain",
      expectedChain = localId, providerChain = providerId
    quit 1
