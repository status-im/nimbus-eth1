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
  web3/eth_api,
  ../validate_proof,
  ../header_store

logScope:
  topics = "verified_proxy"

type
  QuantityTagKind = enum
    LatestBlock
    BlockNumber

  QuantityTag = object
    case kind: QuantityTagKind
    of LatestBlock:
      discard
    of BlockNumber:
      blockNumber: Quantity

func parseQuantityTag(blockTag: BlockTag): Result[QuantityTag, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest":
      return ok(QuantityTag(kind: LatestBlock))
    else:
      return err("Unsupported blockTag: " & tag)
  else:
    let quantity = blockTag.number
    return ok(QuantityTag(kind: BlockNumber, blockNumber: quantity))

template checkPreconditions(proxy: VerifiedRpcProxy) =
  if proxy.headerStore.isEmpty():
    raise newException(ValueError, "Syncing")

proc getHeaderByTag(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): results.Opt[Header] {.raises: [ValueError].} =
  checkPreconditions(proxy)

  let tag = parseQuantityTag(quantityTag).valueOr:
    raise newException(ValueError, error)

  case tag.kind
  of LatestBlock:
    # this will always return some block, as we always checkPreconditions
    proxy.headerStore.latest
  of BlockNumber:
    proxy.headerStore.get(base.BlockNumber(distinctBase(tag.blockNumber)))

proc getHeaderByTagOrThrow(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): Header {.raises: [ValueError].} =
  getHeaderByTag(proxy, quantityTag).valueOr:
    raise newException(ValueError, "No block stored for given tag " & $quantityTag)

proc installEthApiHandlers*(lcProxy: VerifiedRpcProxy) =
  lcProxy.proxy.rpc("eth_chainId") do() -> UInt256:
    lcProxy.chainId

  lcProxy.proxy.rpc("eth_blockNumber") do() -> uint64:
    ## Returns the number of the most recent block.
    let latest = lcProxy.headerStore.latest.valueOr:
      raise newException(ValueError, "Syncing")

    latest.number.uint64

  lcProxy.proxy.rpc("eth_getBalance") do(
    address: Address, quantityTag: BlockTag
  ) -> UInt256:
    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)

      account = (await vp.getAccount(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    account.balance

  lcProxy.proxy.rpc("eth_getStorageAt") do(
    address: Address, slot: UInt256, quantityTag: BlockTag
  ) -> UInt256:
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)
      storage = (await vp.getStorageAt(address, slot, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    storage

  lcProxy.proxy.rpc("eth_getTransactionCount") do(
    address: Address, quantityTag: BlockTag
  ) -> uint64:
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)
      account = (await vp.getAccount(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    account.nonce

  lcProxy.proxy.rpc("eth_getCode") do(
    address: Address, quantityTag: BlockTag
  ) -> seq[byte]:
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)
      code = (await vp.getCode(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    code

  # TODO:
  # Following methods are forwarded directly to the web3 provider and therefore
  # are not validated in any way.
  lcProxy.proxy.registerProxyMethod("net_version")
  lcProxy.proxy.registerProxyMethod("eth_call")
  lcProxy.proxy.registerProxyMethod("eth_sendRawTransaction")
  lcProxy.proxy.registerProxyMethod("eth_getTransactionReceipt")
  lcProxy.proxy.registerProxyMethod("eth_getBlockByNumber")
  lcProxy.proxy.registerProxyMethod("eth_getBlockByHash")

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
