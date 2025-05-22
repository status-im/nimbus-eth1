# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  stint,
  chronos,
  results,
  chronicles,
  eth/common/eth_types_rlp,
  eth/trie/[hexary_proof_verification],
  json_rpc/[rpcproxy, rpcserver, rpcclient],
  web3/[primitives, eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ../types,
  ./blocks

proc getAccountFromProof*(
    stateRoot: Hash32,
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: Hash32,
    accountStorageRoot: Hash32,
    mptNodes: seq[RlpEncodedBytes],
): Result[Account, string] =
  let
    mptNodesBytes = mptNodes.mapIt(distinctBase(it))
    acc = Account(
      nonce: distinctBase(accountNonce),
      balance: accountBalance,
      storageRoot: accountStorageRoot,
      codeHash: accountCodeHash,
    )
    accountEncoded = rlp.encode(acc)
    accountKey = toSeq(keccak256((accountAddress.data)).data)

  let proofResult = verifyMptProof(mptNodesBytes, stateRoot, accountKey, accountEncoded)

  case proofResult.kind
  of MissingKey:
    return ok(EMPTY_ACCOUNT)
  of ValidProof:
    return ok(acc)
  of InvalidProof:
    return err(proofResult.errorMsg)

proc getStorageFromProof(
    account: Account, storageProof: StorageProof
): Result[UInt256, string] =
  let
    storageMptNodes = storageProof.proof.mapIt(distinctBase(it))
    key = toSeq(keccak256(toBytesBE(storageProof.key)).data)
    encodedValue = rlp.encode(storageProof.value)
    proofResult =
      verifyMptProof(storageMptNodes, account.storageRoot, key, encodedValue)

  case proofResult.kind
  of MissingKey:
    return ok(UInt256.zero)
  of ValidProof:
    return ok(storageProof.value)
  of InvalidProof:
    return err(proofResult.errorMsg)

proc getStorageFromProof*(
    stateRoot: Hash32, requestedSlot: UInt256, proof: ProofResponse
): Result[UInt256, string] =
  let account =
    ?getAccountFromProof(
      stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
      proof.storageHash, proof.accountProof,
    )

  if account.storageRoot == EMPTY_ROOT_HASH:
    # valid account with empty storage, in that case getStorageAt
    # return 0 value
    return ok(u256(0))

  if len(proof.storageProof) != 1:
    return err("no storage proof for requested slot")

  let storageProof = proof.storageProof[0]

  if len(storageProof.proof) == 0:
    return err("empty mpt proof for account with not empty storage")

  if storageProof.key != requestedSlot:
    return err("received proof for invalid slot")

  getStorageFromProof(account, storageProof)

proc getAccount*(
    lcProxy: VerifiedRpcProxy,
    address: Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[Result[Account, string]] {.async.} =
  info "Forwarding eth_getAccount", blockNumber

  let
    proof =
      try:
        await lcProxy.rpcClient.eth_getProof(address, @[], blockId(blockNumber))
      except CatchableError as e:
        return err(e.msg)

    account = getAccountFromProof(
      stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
      proof.storageHash, proof.accountProof,
    )

  return account

proc getCode*(
    lcProxy: VerifiedRpcProxy,
    address: Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[Result[seq[byte], string]] {.async.} =
  # get verified account details for the address at blockNumber
  let account = (await lcProxy.getAccount(address, blockNumber, stateRoot)).valueOr:
    return err(error)

  # if the account does not have any code, return empty hex data
  if account.codeHash == EMPTY_CODE_HASH:
    return ok(newSeq[byte]())

  info "Forwarding eth_getCode", blockNumber

  let code =
    try:
      await lcProxy.rpcClient.eth_getCode(address, blockId(blockNumber))
    except CatchableError as e:
      return err(e.msg)

  # verify the byte code. since we verified the account against
  # the state root we just need to verify the code hash
  if account.codeHash == keccak256(code):
    return ok(code)
  else:
    return err("received code doesn't match the account code hash")

proc getStorageAt*(
    lcProxy: VerifiedRpcProxy,
    address: Address,
    slot: UInt256,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[Result[UInt256, string]] {.async.} =
  info "Forwarding eth_getStorageAt", blockNumber

  let
    proof =
      try:
        await lcProxy.rpcClient.eth_getProof(address, @[slot], blockId(blockNumber))
      except CatchableError as e:
        return err(e.msg)

    slotValue = getStorageFromProof(stateRoot, slot, proof)

  return slotValue

proc installEthApiAccountHandlers*(lcProxy: VerifiedRpcProxy) =
  lcProxy.proxy.rpc("eth_getBalance") do(
    address: Address, quantityTag: BlockTag
  ) -> UInt256:
    # When requesting state for `latest` block number, we need to translate
    # `latest` to actual block number as `latest` on proxy and on data provider
    # can mean different blocks and ultimatly piece received piece of state
    # must by validated against correct state root
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)

      account = (await lcProxy.getAccount(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    account.balance

  lcProxy.proxy.rpc("eth_getStorageAt") do(
    address: Address, slot: UInt256, quantityTag: BlockTag
  ) -> UInt256:
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)
      storage = (
        await lcProxy.getStorageAt(address, slot, header.number, header.stateRoot)
      ).valueOr:
        raise newException(ValueError, error)

    storage

  lcProxy.proxy.rpc("eth_getTransactionCount") do(
    address: Address, quantityTag: BlockTag
  ) -> Quantity:
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)
      account = (await lcProxy.getAccount(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    Quantity(account.nonce)

  lcProxy.proxy.rpc("eth_getCode") do(
    address: Address, quantityTag: BlockTag
  ) -> seq[byte]:
    let
      header = lcProxy.getHeaderByTagOrThrow(quantityTag)
      code = (await lcProxy.getCode(address, header.number, header.stateRoot)).valueOr:
        raise newException(ValueError, error)

    code
