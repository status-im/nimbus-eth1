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
  ./accounts

logScope:
  topics = "verified_proxy"

template rpcClient*(vp: VerifiedRpcProxy): RpcClient =
  vp.proxy.getClient()

proc installEthApiHandlers*(vp: VerifiedRpcProxy) =
  vp.proxy.rpc("eth_chainId") do() -> Quantity:
    vp.chainId

  # eth_blockNumber - get latest tag from header store
  vp.proxy.rpc("eth_blockNumber") do() -> Quantity:
    # Returns the number of the most recent block seen by the light client.
    let hLatest = vp.headerStore.latest()
    if hLatest.isNone:
      raise newException(ValueError, "Syncing")

    return Quantity(hLatest.get().number)

  vp.proxy.rpc("eth_getBalance") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> UInt256:
    let
      header = await vp.getHeaderByTag(blockTag)
      account = await vp.getAccount(address, header.number, header.stateRoot)

    account.balance

  vp.proxy.rpc("eth_getStorageAt") do(
    address: addresses.Address, slot: UInt256, blockTag: BlockTag
  ) -> UInt256:
    let header = await vp.getHeaderByTag(blockTag)

    await vp.getStorageAt(address, slot, header.number, header.stateRoot)

  vp.proxy.rpc("eth_getTransactionCount") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> Quantity:
    let
      header = await vp.getHeaderByTag(blockTag)
      account = await vp.getAccount(address, header.number, header.stateRoot)

    Quantity(account.nonce)

  vp.proxy.rpc("eth_getCode") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> seq[byte]:
    let
      header = await vp.getHeaderByTag(blockTag)

    await vp.getCode(address,header.number, header.stateRoot)

  vp.proxy.rpc("eth_call") do(
    args: TransactionArgs, blockTag: BlockTag
  ) -> seq[byte]:

    # eth_call
    # 1. get the code with proof
    let 
      to = if args.to.isSome(): args.to.get()
           else: raise newException(ValueError, "contract address missing in transaction args")
      header = await vp.getHeaderByTag(blockTag)
      code = await vp.getCode(to, header.number, header.stateRoot)

    # 2. get all storage locations that are accessed
    let 
      parent = await vp.getHeaderByHash(header.parentHash)
      accessListResult = await vp.rpcClient.eth_createAccessList(args, blockId(header.number)) 
      accessList = if not accessListResult.error.isSome(): accessListResult.accessList
                   else: raise newException(ValueError, "couldn't get an access list for eth call")

    # 3. pull the storage values that are access along with their accounts and initialize db
    let 
      com = CommonRef.new(newCoreDbRef DefaultDbMemory, nil)
      fork = com.toEVMFork(header)
      vmState = BaseVMState()

    vmState.init(parent, header, com, com.db.baseTxFrame())
    vmState.mutateLedger:
      for accessPair in accessList:
        let 
          accountAddr = accessPair.address
          acc = await vp.getAccount(accountAddr, header.number, header.stateRoot)
          accCode = await vp.getCode(accountAddr, header.number, header.stateRoot)

        db.setNonce(accountAddr, acc.nonce)
        db.setBalance(accountAddr, acc.balance)
        db.setCode(accountAddr, accCode)

        for slot in accessPair.storageKeys:
          let 
            slotInt = UInt256.fromHex(toHex(slot))
            slotValue = await vp.getStorageAt(accountAddr, slotInt, header.number, header.stateRoot) 
          db.setStorage(accountAddr, slotInt, slotValue)
      db.persist(clearEmptyAccount = false) # settle accounts storage

    # 4. run the evm with the initialized storage
    let evmResult = rpcCallEvm(args, header, vmState).valueOr:
      raise newException(ValueError, "rpcCallEvm error: " & $error.code)

    evmResult.output

  # TODO:
  # Following methods are forwarded directly to the web3 provider and therefore
  # are not validated in any way.
  vp.proxy.registerProxyMethod("net_version")
  vp.proxy.registerProxyMethod("eth_sendRawTransaction")
  vp.proxy.registerProxyMethod("eth_getTransactionReceipt")

  # TODO currently we do not handle fullTransactions flag. It require updates on
  # nim-web3 side
#  vp.proxy.rpc("eth_getBlockByNumber") do(
#    blockTag: BlockTag, fullTransactions: bool
#  ) -> Opt[BlockObject]:
#    vp.getBlockByTag(blockTag)
#
#  vp.proxy.rpc("eth_getBlockByHash") do(
#    blockHash: Hash32, fullTransactions: bool
#  ) -> Opt[BlockObject]:
#    vp.blockCache.getPayloadByHash(blockHash)

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
