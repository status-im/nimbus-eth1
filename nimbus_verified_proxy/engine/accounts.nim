# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/sequtils,
  stint,
  chronos,
  results,
  chronicles,
  eth/common/eth_types_rlp,
  eth/trie/[hexary_proof_verification],
  json_rpc/[rpcserver, rpcclient],
  web3/[primitives, eth_api_types, eth_api],
  ../../execution_chain/beacon/web3_eth_conv,
  ./types

proc getAccountFromProof*(
    stateRoot: Hash32,
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: Hash32,
    accountStorageRoot: Hash32,
    mptNodes: seq[RlpEncodedBytes],
): Account {.raises: [VerificationError].} =
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
    return EMPTY_ACCOUNT
  of ValidProof:
    return acc
  of InvalidProof:
    raise newException(VerificationError, proofResult.errorMsg)

proc getStorageFromProof(
    account: Account, storageProof: StorageProof
): UInt256 {.raises: [VerificationError].} =
  let
    storageMptNodes = storageProof.proof.mapIt(distinctBase(it))
    key = toSeq(keccak256(toBytesBE(storageProof.key)).data)
    encodedValue = rlp.encode(storageProof.value)
    proofResult =
      verifyMptProof(storageMptNodes, account.storageRoot, key, encodedValue)

  case proofResult.kind
  of MissingKey:
    return UInt256.zero
  of ValidProof:
    return storageProof.value
  of InvalidProof:
    raise newException(VerificationError, proofResult.errorMsg)

proc getStorageFromProof*(
    stateRoot: Hash32,
    requestedSlot: UInt256,
    proof: ProofResponse,
    storageProofIndex = 0,
): UInt256 {.raises: [VerificationError].} =
  let account = getAccountFromProof(
    stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
    proof.storageHash, proof.accountProof,
  )

  if account.storageRoot == EMPTY_ROOT_HASH:
    # valid account with empty storage, in that case getStorageAt
    # return 0 value
    return u256(0)

  if proof.storageProof.len() <= storageProofIndex:
    # this is not an UnavailableDataError because the unavailable data is in the proof
    raise newException(VerificationError, "no storage proof for requested slot")

  let storageProof = proof.storageProof[storageProofIndex]

  if len(storageProof.proof) == 0:
    raise newException(
      VerificationError, "empty mpt proof for account with not empty storage"
    )

  if storageProof.key != requestedSlot:
    raise newException(VerificationError, "received proof for invalid slot")

  getStorageFromProof(account, storageProof)

proc getAccount*(
    engine: RpcVerificationEngine,
    address: Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[Account] {.async: (raises: [CancelledError, EngineError]).} =
  let
    cacheKey = (stateRoot, address)
    cachedAcc = engine.accountsCache.get(cacheKey)
  if cachedAcc.isSome():
    return cachedAcc.get()

  info "Forwarding eth_getAccount", blockNumber

  let
    proof =
      try:
        await engine.backend.eth_getProof(address, @[], blockId(blockNumber))
      except EthBackendError as e:
        e.msg = "getProof failed for account: " & e.msg
        raise e

    account = getAccountFromProof(
      stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
      proof.storageHash, proof.accountProof,
    )

  engine.accountsCache.put(cacheKey, account)

  return account

proc getCode*(
    engine: RpcVerificationEngine,
    address: Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[seq[byte]] {.async: (raises: [CancelledError, EngineError]).} =
  # get verified account details for the address at blockNumber
  let account = await engine.getAccount(address, blockNumber, stateRoot)

  # if the account does not have any code, return empty hex data
  if account.codeHash == EMPTY_CODE_HASH:
    return newSeq[byte]()

  let
    cacheKey = (stateRoot, address)
    cachedCode = engine.codeCache.get(cacheKey)
  if cachedCode.isSome():
    return cachedCode.get()

  info "Forwarding eth_getCode", blockNumber

  let code =
    try:
      await engine.backend.eth_getCode(address, blockId(blockNumber))
    except EthBackendError as e:
      e.msg = "Code fetch failed: " & e.msg
      raise e

  # verify the byte code. since we verified the account against
  # the state root we just need to verify the code hash
  if account.codeHash == keccak256(code):
    engine.codeCache.put(cacheKey, code)
    return code
  else:
    raise newException(
      VerificationError, "received code doesn't match the account code hash"
    )

proc getStorageAt*(
    engine: RpcVerificationEngine,
    address: Address,
    slot: UInt256,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[UInt256] {.async: (raises: [CancelledError, EngineError]).} =
  let
    cacheKey = (stateRoot, address, slot)
    cachedSlotValue = engine.storageCache.get(cacheKey)
  if cachedSlotValue.isSome():
    return cachedSlotValue.get()

  info "Forwarding eth_getStorageAt", blockNumber

  let
    proof =
      try:
        await engine.backend.eth_getProof(address, @[slot], blockId(blockNumber))
      except EthBackendError as e:
        e.msg = "getProof failed for account: " & e.msg
        raise e

    slotValue = getStorageFromProof(stateRoot, slot, proof)

  engine.storageCache.put(cacheKey, slotValue)

  return slotValue

proc populateCachesForAccountAndSlots(
    engine: RpcVerificationEngine,
    address: Address,
    slots: seq[UInt256],
    blockNumber: base.BlockNumber,
    stateRoot: Root,
) {.async: (raises: [CancelledError, EngineError]).} =
  var slotsToFetch: seq[UInt256]
  for s in slots:
    let storageCacheKey = (stateRoot, address, s)
    if engine.storageCache.get(storageCacheKey).isNone():
      slotsToFetch.add(s)

  let accountCacheKey = (stateRoot, address)

  if engine.accountsCache.get(accountCacheKey).isNone() or slotsToFetch.len() > 0:
    let
      proof =
        try:
          await engine.backend.eth_getProof(address, slotsToFetch, blockId(blockNumber))
        except EthBackendError as e:
          e.msg = "getProof failed for populating accounts and slots cache: " & e.msg
          raise e

      account = getAccountFromProof(
        stateRoot, proof.address, proof.balance, proof.nonce, proof.codeHash,
        proof.storageHash, proof.accountProof,
      )

    engine.accountsCache.put(accountCacheKey, account)

    for i, s in slotsToFetch:
      let
        slotValue = getStorageFromProof(stateRoot, s, proof, i)
        storageCacheKey = (stateRoot, address, s)

      engine.storageCache.put(storageCacheKey, slotValue)

proc populateCachesUsingAccessList*(
    engine: RpcVerificationEngine,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
    tx: TransactionArgs,
) {.async: (raises: [CancelledError, EngineError]).} =
  let accessListRes: AccessListResult =
    try:
      await engine.backend.eth_createAccessList(tx, blockId(blockNumber))
    except EthBackendError as e:
      e.msg = "AccessList fetch failed for populating cache: " & e.msg
      raise e

  var futs = newSeqOfCap[Future[void]](accessListRes.accessList.len())
  for accessPair in accessListRes.accessList:
    let slots = accessPair.storageKeys.mapIt(UInt256.fromBytesBE(it.data))
    futs.add engine.populateCachesForAccountAndSlots(
      accessPair.address, slots, blockNumber, stateRoot
    )

  await allFutures(futs)
