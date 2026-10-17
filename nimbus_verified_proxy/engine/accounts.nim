# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
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

logScope:
  topics = "vp_engine"

proc getAccountFromProof*(
    stateRoot: Hash32,
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: Hash32,
    accountStorageRoot: Hash32,
    mptNodes: seq[RlpEncodedBytes],
): EngineResult[Account] =
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
    # we leave the error untagged so the backend responsible for
    # the error can be tagged. See tagBackend impl in types.nim
    return err((VerificationError, proofResult.errorMsg, UNTAGGED))

proc getStorageFromProof(
    account: Account, storageProof: StorageProof
): EngineResult[UInt256] =
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
    # we leave the error untagged so the backend responsible for
    # the error can be tagged. See tagBackend impl in types.nim
    return err((VerificationError, proofResult.errorMsg, UNTAGGED))

proc getStorageFromProof*(
    account: Account,
    requestedSlot: UInt256,
    proof: ProofResponse,
    storageProofIndex = 0,
): EngineResult[UInt256] =
  if account.storageRoot == EMPTY_ROOT_HASH:
    # valid account with empty storage, in that case getStorageAt
    # return 0 value
    return ok(u256(0))

  if proof.storageProof.len() <= storageProofIndex:
    # we leave the error untagged so the backend responsible for
    # the error can be tagged. See tagBackend impl in types.nim
    return err((VerificationError, "no storage proof for requested slot", UNTAGGED))

  let storageProof = proof.storageProof[storageProofIndex]

  if len(storageProof.proof) == 0:
    # we leave the error untagged so the backend responsible for
    # the error can be tagged. See tagBackend impl in types.nim
    return err(
      (
        VerificationError, "empty mpt proof for account with not empty storage",
        UNTAGGED,
      )
    )

  if storageProof.key != requestedSlot:
    # we leave the error untagged so the backend responsible for
    # the error can be tagged. See tagBackend impl in types.nim
    return err((VerificationError, "received proof for invalid slot", UNTAGGED))

  getStorageFromProof(account, storageProof)

proc getStorageFromProof*(
    stateRoot: Hash32,
    address: Address,
    requestedSlot: UInt256,
    proof: ProofResponse,
    storageProofIndex = 0,
): EngineResult[UInt256] =
  let account = ?getAccountFromProof(
    stateRoot, address, proof.balance, proof.nonce, proof.codeHash, proof.storageHash,
    proof.accountProof,
  )

  getStorageFromProof(account, requestedSlot, proof, storageProofIndex)

proc getAccount*(
    engine: RpcVerificationEngine,
    address: Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[EngineResult[Account]] {.async: (raises: [CancelledError]).} =
  let
    cacheKey = (stateRoot, address)
    cachedAcc = engine.accountsCache.get(cacheKey)
  if cachedAcc.isSome():
    return ok(cachedAcc.get())

  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetProof))
    proof = ?(
      (await backend.eth_getProof(address, newSeq[Bytes32](), blockId(blockNumber))).tagBackend(
        backendIdx
      )
    )

    account = ?(
      getAccountFromProof(
        stateRoot, address, proof.balance, proof.nonce, proof.codeHash,
        proof.storageHash, proof.accountProof,
      )
      .tagBackend(backendIdx)
    )

  engine.accountsCache.put(cacheKey, account)

  return ok(account)

proc getCode*(
    engine: RpcVerificationEngine,
    address: Address,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
  # get verified account details for the address at blockNumber
  let account = ?(await engine.getAccount(address, blockNumber, stateRoot))

  # if the account does not have any code, return empty hex data
  if account.codeHash == EMPTY_CODE_HASH:
    return ok(newSeq[byte]())

  let
    cacheKey = (stateRoot, address)
    cachedCode = engine.codeCache.get(cacheKey)
  if cachedCode.isSome():
    return ok(cachedCode.get())

  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetCode))
    code = ?(
      (await backend.eth_getCode(address, blockId(blockNumber))).tagBackend(backendIdx)
    )

  # verify the byte code. since we verified the account against
  # the state root we just need to verify the code hash
  if account.codeHash == keccak256(code):
    engine.codeCache.put(cacheKey, code)
    return ok(code)
  else:
    return err(
      (
        VerificationError, "received code doesn't match the account code hash",
        backendIdx,
      )
    )

proc getStorageAt*(
    engine: RpcVerificationEngine,
    address: Address,
    slots: seq[UInt256],
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[EngineResult[seq[UInt256]]] {.async: (raises: [CancelledError]).} =
  var
    slotValues = newSeq[UInt256](slots.len())
    slotsToFetch: seq[UInt256]
    slotsToFetchIdx: seq[int]
  for i, s in slots:
    let cachedSlotValue = engine.storageCache.get((stateRoot, address, s))
    if cachedSlotValue.isSome():
      slotValues[i] = cachedSlotValue.get()
    else:
      slotsToFetch.add(s)
      slotsToFetchIdx.add(i)

  if slotsToFetch.len() == 0:
    return ok(slotValues)

  let
    (backend, backendIdx) = ?(engine.executionBackendFor(GetProof))
    proof = ?(
      (
        await backend.eth_getProof(
          address, slotsToFetch.toStorageKeys(), blockId(blockNumber)
        )
      ).tagBackend(backendIdx)
    )

    account = ?(
      getAccountFromProof(
        stateRoot, address, proof.balance, proof.nonce, proof.codeHash,
        proof.storageHash, proof.accountProof,
      )
      .tagBackend(backendIdx)
    )

  engine.accountsCache.put((stateRoot, address), account)

  for i, s in slotsToFetch:
    let slotValue = ?(getStorageFromProof(account, s, proof, i).tagBackend(backendIdx))
    engine.storageCache.put((stateRoot, address, s), slotValue)
    slotValues[slotsToFetchIdx[i]] = slotValue

  ok(slotValues)

proc populateCachesForAccountAndSlots(
    engine: RpcVerificationEngine,
    address: Address,
    slots: seq[UInt256],
    blockNumber: base.BlockNumber,
    stateRoot: Root,
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  var slotsToFetch: seq[UInt256]
  for s in slots:
    let storageCacheKey = (stateRoot, address, s)
    if engine.storageCache.get(storageCacheKey).isNone():
      slotsToFetch.add(s)

  let accountCacheKey = (stateRoot, address)

  if engine.accountsCache.get(accountCacheKey).isNone() or slotsToFetch.len() > 0:
    let
      (backend, backendIdx) = ?(engine.executionBackendFor(GetProof))
      proof = ?(
        (
          await backend.eth_getProof(
            address, slotsToFetch.toStorageKeys(), blockId(blockNumber)
          )
        ).tagBackend(backendIdx)
      )

      account = ?(
        getAccountFromProof(
          stateRoot, address, proof.balance, proof.nonce, proof.codeHash,
          proof.storageHash, proof.accountProof,
        )
        .tagBackend(backendIdx)
      )

    engine.accountsCache.put(accountCacheKey, account)

    for i, s in slotsToFetch:
      let
        slotValue = ?(getStorageFromProof(account, s, proof, i).tagBackend(backendIdx))
        storageCacheKey = (stateRoot, address, s)

      engine.storageCache.put(storageCacheKey, slotValue)

  ok()

proc populateCachesUsingAccessList*(
    engine: RpcVerificationEngine,
    blockNumber: base.BlockNumber,
    stateRoot: Root,
    tx: TransactionArgs,
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  let
    (backend, backendIdx) = ?(engine.executionBackendFor(CreateAccessList))
    accessListRes: AccessListResult = ?(
      (await backend.eth_createAccessList(tx, blockId(blockNumber))).tagBackend(
        backendIdx
      )
    )

  var futs = newSeqOfCap[Future[EngineResult[void]]](accessListRes.accessList.len())
  for accessPair in accessListRes.accessList:
    let slots = accessPair.storageKeys.mapIt(UInt256.fromBytesBE(it.data))
    futs.add engine.populateCachesForAccountAndSlots(
      accessPair.address, slots, blockNumber, stateRoot
    )

  await allFutures(futs)

  ok()
