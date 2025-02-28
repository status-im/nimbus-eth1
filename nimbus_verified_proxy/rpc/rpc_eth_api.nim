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
  ../header_store

logScope:
  topics = "verified_proxy"

type
  VerifiedRpcProxy* = ref object
    proxy: RpcProxy
    headerStore: HeaderStore
    chainId: Quantity

  BlockTag = eth_api_types.RtBlockIdentifier

template checkPreconditions(proxy: VerifiedRpcProxy) =
  if proxy.headerStore.isEmpty():
    raise newException(ValueError, "Syncing")

template rpcClient(lcProxy: VerifiedRpcProxy): RpcClient =
  lcProxy.proxy.getClient()

proc resolveTag(
    self: VerifiedRpcProxy, blockTag: BlockTag
): base.BlockNumber {.raises: [ValueError].} =
  self.checkPreconditions()

  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii()
    case tag
    of "latest":
      let hLatest = self.headerStore.latest()
      if hLatest.isSome:
        return hLatest.get().number
      else:
        raise newException(ValueError, "No block stored for given tag " & $blockTag)
    else:
      raise newException(ValueError, "No support for block tag " & $blockTag)
  else:
    return base.BlockNumber(distinctBase(blockTag.number))

# TODO: pull a header from the RPC if not in cache
proc getHeaderByHash(
    self: VerifiedRpcProxy, blockHash: Hash32
): Header {.raises: [ValueError].} =
  self.checkPreconditions()
  self.headerStore.get(blockHash).valueOr:
    raise newException(ValueError, "No block stored for given tag " & $blockHash)

# TODO: pull a header from the RPC if not in cache
proc getHeaderByTag(
    self: VerifiedRpcProxy, blockTag: BlockTag
): Header {.raises: [ValueError].} =
  let n = self.resolveTag(blockTag)
  self.headerStore.get(n).valueOr:
    raise newException(ValueError, "No block stored for given tag " & $blockTag)

proc getAccount(
    lcProxy: VerifiedRpcProxy,
    address: addresses.Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root
): Future[Account] {.async: (raises: [ValueError, CatchableError]).} =
  let
    proof = await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))
    account = getAccountFromProof(
      stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
      proof.storageHash, proof.accountProof,
    ).valueOr:
      raise newException(ValueError, error)

  return account

proc getCode(
    lcProxy: VerifiedRpcProxy, 
    address: addresses.Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root
): Future[seq[byte]] {.async: (raises: [ValueError, CatchableError]).} = 
  # get verified account details for the address at blockNumber
  let account = await lcProxy.getAccount(address, blockNumber, stateRoot)

  # if the account does not have any code, return empty hex data
  if account.codeHash == EMPTY_CODE_HASH:
    return @[]

  info "Forwarding eth_getCode", blockNumber

  let code = await lcProxy.rpcClient.eth_getCode(address, blockId(blockNumber))

  # verify the byte code. since we verified the account against 
  # the state root we just need to verify the code hash
  if isValidCode(account, code):
    return code
  else:
    raise newException(ValueError, "received code doesn't match the account code hash")

proc getStorageAt(
    lcProxy: VerifiedRpcProxy, 
    address: addresses.Address, 
    slot: UInt256, 
    blockNumber: base.BlockNumber,
    stateRoot: Root
): Future[UInt256] {.async: (raises: [ValueError, CatchableError]).} = 

  info "Forwarding eth_getStorageAt", blockNumber

  let 
    proof = await lcProxy.rpcClient.eth_getProof(address, @[slot], blockId(blockNumber))
    slotValue = getStorageData(stateRoot, slot, proof).valueOr:
      raise newException(ValueError, error)

  slotValue

proc installEthApiHandlers*(lcProxy: VerifiedRpcProxy) =
  lcProxy.proxy.rpc("eth_chainId") do() -> UInt256:
    lcProxy.chainId

  lcProxy.proxy.rpc("eth_blockNumber") do() -> Quantity:
    # Returns the number of the most recent block seen by the light client.
    lcProxy.checkPreconditions()

    let hLatest = lcProxy.headerStore.latest()
    if hLatest.isNone:
      raise newException(ValueError, "Syncing")

    return Quantity(hLatest.get().number)

  lcProxy.proxy.rpc("eth_getBalance") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> UInt256:
    let
      blockNumber = lcProxy.resolveTag(blockTag)
      header = lcProxy.headerStore.get(blockNumber).valueOr:
        raise newException(ValueError, "No block stored for given tag " & $blockTag)
      account = await lcProxy.getAccount(address, blockNumber, header.stateRoot)

    account.balance

  lcProxy.proxy.rpc("eth_getStorageAt") do(
    address: addresses.Address, slot: UInt256, blockTag: BlockTag
  ) -> UInt256:
    let
      blockNumber = lcProxy.resolveTag(blockTag)
      header = lcProxy.headerStore.get(blockNumber).valueOr:
        raise newException(ValueError, "No block stored for given tag " & $blockTag)

    await lcProxy.getStorageAt(address, slot, blockNumber, header.stateRoot)

  lcProxy.proxy.rpc("eth_getTransactionCount") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> Quantity:
    let
      blockNumber = lcProxy.resolveTag(blockTag)
      header = lcProxy.headerStore.get(blockNumber).valueOr:
        raise newException(ValueError, "No block stored for given tag " & $blockTag)

      account = await lcProxy.getAccount(address, blockNumber, header.stateRoot)

    Quantity(account.nonce)

  lcProxy.proxy.rpc("eth_getCode") do(
    address: addresses.Address, blockTag: BlockTag
  ) -> seq[byte]:
    let
      blockNumber = lcProxy.resolveTag(blockTag)
      header = lcProxy.headerStore.get(blockNumber).valueOr:
        raise newException(ValueError, "No block stored for given tag " & $blockTag)

    await lcProxy.getCode(address, blockNumber, header.stateRoot)

  lcProxy.proxy.rpc("eth_call") do(
    args: TransactionArgs, blockTag: BlockTag
  ) -> seq[byte]:

    # eth_call
    # 1. get the code with proof
    let 
      to = if args.to.isSome(): args.to.get()
           else: raise newException(ValueError, "contract address missing in transaction args")
      blockNumber = lcProxy.resolveTag(blockTag)
      header = lcProxy.headerStore.get(blockNumber).valueOr:
        raise newException(ValueError, "No block stored for given tag " & $blockTag)
      code = await lcProxy.getCode(to, blockNumber, header.stateRoot)

    # 2. get all storage locations that are accessed
    let 
      parent = lcProxy.headerStore.get(header.parentHash).valueOr:
        raise newException(ValueError, "No block stored for given tag " & $blockTag)
      accessListResult = await lcProxy.rpcClient.eth_createAccessList(args, blockId(blockNumber)) 
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
          acc = await lcProxy.getAccount(accountAddr, blockNumber, header.stateRoot)
          accCode = await lcProxy.getCode(accountAddr, blockNumber, header.stateRoot)

        db.setNonce(accountAddr, acc.nonce)
        db.setBalance(accountAddr, acc.balance)
        db.setCode(accountAddr, accCode)

        for slot in accessPair.storageKeys:
          let 
            slotInt = UInt256.fromHex(toHex(slot))
            slotValue = await lcProxy.getStorageAt(accountAddr, slotInt, blockNumber, header.stateRoot) 
          db.setStorage(accountAddr, slotInt, slotValue)
      db.persist(clearEmptyAccount = false) # settle accounts storage

    # 4. run the evm with the initialized storage
    let evmResult = rpcCallEvm(args, header, vmState).valueOr:
      raise newException(ValueError, "rpcCallEvm error: " & $error.code)

    evmResult.output

  # TODO:
  # Following methods are forwarded directly to the web3 provider and therefore
  # are not validated in any way.
  lcProxy.proxy.registerProxyMethod("net_version")
  lcProxy.proxy.registerProxyMethod("eth_sendRawTransaction")
  lcProxy.proxy.registerProxyMethod("eth_getTransactionReceipt")

  # TODO currently we do not handle fullTransactions flag. It require updates on
  # nim-web3 side
#  lcProxy.proxy.rpc("eth_getBlockByNumber") do(
#    blockTag: BlockTag, fullTransactions: bool
#  ) -> Opt[BlockObject]:
#    lcProxy.getBlockByTag(blockTag)
#
#  lcProxy.proxy.rpc("eth_getBlockByHash") do(
#    blockHash: Hash32, fullTransactions: bool
#  ) -> Opt[BlockObject]:
#    lcProxy.blockCache.getPayloadByHash(blockHash)

proc new*(
    T: type VerifiedRpcProxy, proxy: RpcProxy, headerStore: HeaderStore, chainId: Quantity
): T =
  VerifiedRpcProxy(proxy: proxy, headerStore: headerStore, chainId: chainId)

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

proc verifyChaindId*(p: VerifiedRpcProxy): Future[void] {.async.} =
  let localId = p.chainId

  # retry 2 times, if the data provider fails despite the re-tries, propagate
  # exception to the caller.
  let providerId =
    awaitWithRetries(p.rpcClient.eth_chainId(), retries = 2, timeout = seconds(30))

  # This is a chain/network mismatch error between the Nimbus verified proxy and
  # the application using it. Fail fast to avoid misusage. The user must fix
  # the configuration.
  if localId != providerId:
    fatal "The specified data provider serves data for a different chain",
      expectedChain = localId, providerChain = providerId
    quit 1
