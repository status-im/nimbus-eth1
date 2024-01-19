# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, typetraits, options, times],
  chronicles,
  chronos,
  nimcrypto,
  stint,
  stew/byteutils,
  json_rpc/rpcclient,
  eth/common,
  eth/rlp,
  eth/trie/hexary_proof_verification,
  eth/p2p,
  eth/p2p/rlpx,
  eth/p2p/private/p2p_types,
  ../../../sync/protocol,
  ../../../db/[core_db, distinct_tries, incomplete_db, storage_types],
  ../data_sources,
  ../../../beacon/web3_eth_conv,
  web3/conversions,
  web3

when defined(legacy_eth66_enabled):
  import
    ../../../sync/protocol/eth66 as proto_eth66
  from ../../../sync/protocol/eth66 import getNodeData

export AsyncOperationFactory, AsyncDataSource

type
  BlockHeader = eth_types.BlockHeader

var durationSpentDoingFetches*: times.Duration
var fetchCounter*: int

proc makeAnRpcClient*(web3Url: string): Future[RpcClient] {.async.} =
  let myWeb3: Web3 = waitFor(newWeb3(web3Url))
  return myWeb3.provider

func blockHeaderFromBlockObject(o: BlockObject): BlockHeader =
  let nonce: BlockNonce = if o.nonce.isSome: distinctBase(o.nonce.get) else: default(BlockNonce)
  BlockHeader(
    parentHash: o.parentHash.ethHash,
    ommersHash: o.sha3Uncles.ethHash,
    coinbase: o.miner.ethAddr,
    stateRoot: o.stateRoot.ethHash,
    txRoot: o.transactionsRoot.ethHash,
    receiptRoot: o.receiptsRoot.ethHash,
    bloom: distinctBase(o.logsBloom),
    difficulty: o.difficulty,
    blockNumber: o.number.u256,
    gasLimit: GasInt(distinctBase(o.gasLimit)),
    gasUsed: GasInt(distinctBase(o.gasUsed)),
    timestamp: EthTime(distinctBase(o.timestamp)),
    extraData: distinctBase(o.extraData),
    #mixDigest: o.mixHash.ethHash, # AARDVARK what's this?
    nonce: nonce,
    fee: o.baseFeePerGas,
    withdrawalsRoot: ethHash o.withdrawalsRoot,
    blobGasUsed: u64 o.blobGasUsed,
    excessBlobGas: u64 o.excessBlobGas
  )

proc fetchBlockHeaderWithHash*(rpcClient: RpcClient, h: common.Hash256): Future[common.BlockHeader] {.async.} =
  let t0 = now()
  let blockObject: BlockObject = await rpcClient.eth_getBlockByHash(h.w3Hash, false)
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return blockHeaderFromBlockObject(blockObject)

proc fetchBlockHeaderWithNumber*(rpcClient: RpcClient, n: common.BlockNumber): Future[common.BlockHeader] {.async.} =
  let t0 = now()
  let bid = blockId(n.truncate(uint64))
  let blockObject: BlockObject = await rpcClient.eth_getBlockByNumber(bid, false)
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return blockHeaderFromBlockObject(blockObject)

#[
proc parseBlockBodyAndFetchUncles(rpcClient: RpcClient, r: JsonNode): Future[BlockBody] {.async.} =
  var body: BlockBody
  for tn in r["transactions"].getElems:
    body.transactions.add(parseTransaction(tn))
  for un in r["uncles"].getElems:
    let uncleHash: Hash256 = un.getStr.ethHash
    let uncleHeader = await fetchBlockHeaderWithHash(rpcClient, uncleHash)
    body.uncles.add(uncleHeader)
  return body

proc fetchBlockHeaderAndBodyWithHash*(rpcClient: RpcClient, h: Hash256): Future[(BlockHeader, BlockBody)] {.async.} =
  let t0 = now()
  let r = request("eth_getBlockByHash", %[%h.prefixHex, %true], some(rpcClient))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  if r.kind == JNull:
    error "requested block not available", blockHash=h
    raise newException(ValueError, "Error when retrieving block header and body")
  let header = parseBlockHeader(r)
  let body = await parseBlockBodyAndFetchUncles(rpcClient, r)
  return (header, body)

proc fetchBlockHeaderAndBodyWithNumber*(rpcClient: RpcClient, n: BlockNumber): Future[(BlockHeader, BlockBody)] {.async.} =
  let t0 = now()
  let r = request("eth_getBlockByNumber", %[%n.prefixHex, %true], some(rpcClient))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  if r.kind == JNull:
    error "requested block not available", blockNumber=n
    raise newException(ValueError, "Error when retrieving block header and body")
  let header = parseBlockHeader(r)
  let body = await parseBlockBodyAndFetchUncles(rpcClient, r)
  return (header, body)
]#

proc fetchBlockHeaderAndBodyWithHash*(rpcClient: RpcClient, h: common.Hash256): Future[(common.BlockHeader, BlockBody)] {.async.} =
  doAssert(false, "AARDVARK not implemented")

proc fetchBlockHeaderAndBodyWithNumber*(rpcClient: RpcClient, n: common.BlockNumber): Future[(common.BlockHeader, BlockBody)] {.async.} =
  doAssert(false, "AARDVARK not implemented")

func mdigestFromFixedBytes*(arg: FixedBytes[32]): MDigest[256] =
  MDigest[256](data: distinctBase(arg))

func mdigestFromString*(s: string): MDigest[256] =
  mdigestFromFixedBytes(FixedBytes[32].fromHex(s))

type
  AccountProof* = seq[seq[byte]]

proc fetchAccountAndSlots*(rpcClient: RpcClient, address: EthAddress, slots: seq[UInt256], blockNumber: common.BlockNumber): Future[(Account, AccountProof, seq[StorageProof])] {.async.} =
  let t0 = now()
  debug "Got to fetchAccountAndSlots", address=address, slots=slots, blockNumber=blockNumber
  let blockNumberUint64 = blockNumber.truncate(uint64)
  let a = web3.Address(address)
  let bid = blockId(blockNumber.truncate(uint64))
  debug "About to call eth_getProof", address=address, slots=slots, blockNumber=blockNumber
  let proofResponse: ProofResponse = await rpcClient.eth_getProof(a, slots, bid)
  debug "Received response to eth_getProof", proofResponse=proofResponse

  let acc = Account(
    nonce: distinctBase(proofResponse.nonce),
    balance: proofResponse.balance,
    storageRoot: mdigestFromFixedBytes(proofResponse.storageHash),
    codeHash: mdigestFromFixedBytes(proofResponse.codeHash)
  )
  debug "Parsed response to eth_getProof", acc=acc
  let mptNodesBytes: seq[seq[byte]] = proofResponse.accountProof.mapIt(distinctBase(it))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return (acc, mptNodesBytes, proofResponse.storageProof)

proc fetchCode*(client: RpcClient, blockNumber: common.BlockNumber, address: EthAddress): Future[seq[byte]] {.async.} =
  let t0 = now()
  let a = web3.Address(address)
  let bid = blockId(blockNumber.truncate(uint64))
  let fetchedCode: seq[byte] = await client.eth_getCode(a, bid)
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return fetchedCode

const bytesLimit = 2 * 1024 * 1024
const maxNumberOfPeersToAttempt = 3

proc fetchUsingGetTrieNodes(peer: Peer, stateRoot: common.Hash256, paths: seq[SnapTriePaths]): Future[seq[seq[byte]]] {.async.} =
  let r = await peer.getTrieNodes(stateRoot, paths, bytesLimit)
  if r.isNone:
    raise newException(CatchableError, "AARDVARK: received None in GetTrieNodes response")
  else:
    return r.get.nodes

proc fetchUsingGetNodeData(peer: Peer, nodeHashes: seq[common.Hash256]): Future[seq[seq[byte]]] {.async.} =
  #[
  let r: Option[seq[seq[byte]]] = none[seq[seq[byte]]]() # AARDVARK await peer.getNodeData(nodeHashes)
  if r.isNone:
    raise newException(CatchableError, "AARDVARK: received None in GetNodeData response")
  else:
    echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fetchUsingGetNodeData received nodes: " & $(r.get.data)
    return r.get.data
  ]#
  # AARDVARK whatever
  return @[]

proc findPeersAndMakeSomeCalls[R](peerPool: PeerPool, protocolName: string, protocolType: typedesc, initiateAttempt: (proc(p: Peer): Future[R] {.gcsafe, raises: [].})): Future[seq[Future[R]]] {.async.} =
  var attempts: seq[Future[R]]
  while true:
    #info("AARDVARK: findPeersAndMakeSomeCalls about to loop through the peer pool", count=peerPool.connectedNodes.len)
    for nodeOfSomeSort, peer in peerPool.connectedNodes:
      if peer.supports(protocolType):
        info("AARDVARK: findPeersAndMakeSomeCalls calling peer", protocolName, peer)
        attempts.add(initiateAttempt(peer))
        if attempts.len >= maxNumberOfPeersToAttempt:
          break
      #else:
      #  info("AARDVARK: peer does not support protocol", protocolName, peer)
    if attempts.len == 0:
      warn("AARDVARK: findPeersAndMakeSomeCalls did not find any peers; waiting and trying again", protocolName, totalPeerPoolSize=peerPool.connectedNodes.len)
      await sleepAsync(chronos.seconds(5))
    else:
      if attempts.len < maxNumberOfPeersToAttempt:
        warn("AARDVARK: findPeersAndMakeSomeCalls did not find enough peers, but found some", protocolName, totalPeerPoolSize=peerPool.connectedNodes.len, found=attempts.len)
      break
  return attempts

proc findPeersAndMakeSomeAttemptsToCallGetTrieNodes(peerPool: PeerPool, stateRoot: common.Hash256, paths: seq[SnapTriePaths]): Future[seq[Future[seq[seq[byte]]]]] =
  findPeersAndMakeSomeCalls(peerPool, "snap", protocol.snap, (proc(peer: Peer): Future[seq[seq[byte]]] = fetchUsingGetTrieNodes(peer, stateRoot, paths)))

#[
proc findPeersAndMakeSomeAttemptsToCallGetNodeData(peerPool: PeerPool, stateRoot: Hash256, nodeHashes: seq[Hash256]): Future[seq[Future[seq[seq[byte]]]]] =
  findPeersAndMakeSomeCalls(peerPool, "eth66", eth66, (proc(peer: Peer): Future[seq[seq[byte]]] = fetchUsingGetNodeData(peer, nodeHashes)))
]#

proc fetchNodes(peerPool: PeerPool, stateRoot: common.Hash256, paths: seq[SnapTriePaths], nodeHashes: seq[common.Hash256]): Future[seq[seq[byte]]] {.async.} =
  let attempts = await findPeersAndMakeSomeAttemptsToCallGetTrieNodes(peerPool, stateRoot, paths)
  #let attempts = await findPeersAndMakeSomeAttemptsToCallGetNodeData(peerPool, stateRoot, nodeHashes)
  let completedAttempt = await one(attempts)
  let nodes: seq[seq[byte]] = completedAttempt.read
  info("AARDVARK: fetchNodes received nodes", nodes)
  return nodes

proc verifyFetchedAccount(stateRoot: common.Hash256, address: EthAddress, acc: Account, accProof: seq[seq[byte]]): Result[void, string] =
  let accKey = toSeq(keccakHash(address).data)
  let accEncoded = rlp.encode(acc)
  let accProofResult = verifyMptProof(accProof, stateRoot, accKey, accEncoded)
  case accProofResult.kind
  of ValidProof:
    return ok()
  of MissingKey:
    # For an account that doesn't exist yet, which is fine.
    return ok()
  of InvalidProof:
    return err(accProofResult.errorMsg)

type
  CodeFetchingInfo = tuple[blockNumber: common.BlockNumber, address: EthAddress]

proc fetchCode(client: RpcClient, p: CodeFetchingInfo): Future[seq[byte]] {.async.} =
  let (blockNumber, address) = p
  let fetchedCode = await fetchCode(client, blockNumber, address)
  return fetchedCode

proc verifyFetchedCode(fetchedCode: seq[byte], desiredCodeHash: common.Hash256): Result[void, common.Hash256] =
  let fetchedCodeHash = keccakHash(fetchedCode)
  if desiredCodeHash == fetchedCodeHash:
    ok()
  else:
    err(fetchedCodeHash)

proc fetchAndVerifyCode(client: RpcClient, p: CodeFetchingInfo, desiredCodeHash: common.Hash256): Future[seq[byte]] {.async.} =
    let fetchedCode: seq[byte] = await fetchCode(client, p)
    let verificationRes = verifyFetchedCode(fetchedCode, desiredCodeHash)
    if verificationRes.isOk():
      return fetchedCode
    else:
      let fetchedCodeHash = verificationRes.error
      error("code hash values do not match", p=p, desiredCodeHash=desiredCodeHash, fetchedCodeHash=fetchedCodeHash)
      raise newException(CatchableError, "async code received code for " & $(p.address) & " whose hash (" & $(fetchedCodeHash) & ") does not match the desired hash (" & $(desiredCodeHash) & ")")

proc putCode*(db: CoreDbRef, codeHash: common.Hash256, code: seq[byte]) =
  when defined(geth):
    db.kvt.put(codeHash.data, code)
  else:
    db.kvt.put(contractHashKey(codeHash).toOpenArray, code)

proc putCode*(trie: AccountsTrie, codeHash: common.Hash256, code: seq[byte]) =
  putCode(trie.db, codeHash, code)

proc storeCode(trie: AccountsTrie, p: CodeFetchingInfo, desiredCodeHash: common.Hash256, fetchedCode: seq[byte]) =
  trie.putCode(desiredCodeHash, fetchedCode)

proc assertThatWeHaveStoredCode(trie: AccountsTrie, p: CodeFetchingInfo, codeHash: common.Hash256) =
  # FIXME-Adam: this is a bit wrong because we're not checking it against the blockNumber, only the address. (That is,
  # if the code for this address has *changed* (which is unlikely), this check isn't the right thing to do.)
  let maybeFoundCode = trie.maybeGetCode(p.address)
  if maybeFoundCode.isNone:
    error("code didn't get put into the db", p=p, codeHash=codeHash)
    doAssert false, "code didn't get put into the db"
  else:
    let foundCode = maybeFoundCode.get
    let foundCodeHash = keccakHash(foundCode)
    if foundCodeHash != codeHash:
      error("code does not have the right hash", p=p, codeHash=codeHash, foundCode=foundCode)
      doAssert false, "code does not have the right hash"


proc assertThatWeHaveStoredAccount(trie: AccountsTrie, address: EthAddress, fetchedAcc: Account, isForTheNewTrie: bool = false) =
  let foundAcc = ifNodesExistGetAccount(trie, address).get
  if fetchedAcc != foundAcc:
    error "account didn't come out the same", address=address, fetchedAcc=fetchedAcc, foundAcc=foundAcc, isForTheNewTrie=isForTheNewTrie
    doAssert false, "account didn't come out the same"
  doAssert(trie.hasAllNodesForAccount(address), "Can I check the account this way, too?")


proc verifyFetchedSlot(accountStorageRoot: common.Hash256, slot: UInt256, fetchedVal: UInt256, storageMptNodes: seq[seq[byte]]): Result[void, string] =
  if storageMptNodes.len == 0:
    # I think an empty storage proof is okay; I see lots of these
    # where the account is empty and the value is zero.
    return ok()
  else:
    let storageKey = toSeq(keccakHash(toBytesBE(slot)).data)
    let storageValueEncoded = rlp.encode(fetchedVal)
    let storageProofResult = verifyMptProof(storageMptNodes, accountStorageRoot, storageKey, storageValueEncoded)
    case storageProofResult.kind
    of ValidProof:
      return ok()
    of MissingKey:
      # This is for a slot that doesn't have anything stored at it, but that's fine.
      return ok()
    of InvalidProof:
      return err(storageProofResult.errorMsg)


proc assertThatWeHaveStoredSlot(trie: AccountsTrie, address: EthAddress, acc: Account, slot: common.UInt256, fetchedVal: UInt256, isForTheNewTrie: bool = false) =
  if acc.storageRoot == EMPTY_ROOT_HASH and fetchedVal.isZero:
    # I believe this is okay.
    discard
  else:
    let foundVal = ifNodesExistGetStorage(trie, address, slot).get
    if (fetchedVal != foundVal):
      error("slot didn't come out the same", address=address, slot=slot, fetchedVal=fetchedVal, foundVal=foundVal, isForTheNewTrie=isForTheNewTrie)
      doAssert false, "slot didn't come out the same"


proc verifyFetchedBlockHeader(fetchedHeader: common.BlockHeader, desiredBlockNumber: common.BlockNumber): Result[void, common.BlockNumber] =
  # *Can* we do anything to verify this header, given that all we know
  # is the desiredBlockNumber and we want to run statelessly so we don't
  # know what block hash we want?
  ok()

proc storeBlockHeader(chainDB: CoreDbRef, header: common.BlockHeader) =
  chainDB.persistHeaderToDbWithoutSetHeadOrScore(header)

proc assertThatWeHaveStoredBlockHeader(chainDB: CoreDbRef, blockNumber: common.BlockNumber, header: common.BlockHeader) =
  let h = chainDB.getBlockHash(blockNumber)
  doAssert(h == header.blockHash, "stored the block header for block " & $(blockNumber))

proc raiseExceptionIfError[V, E](whatAreWeVerifying: V, r: Result[void, E]) =
  if r.isErr:
    error("async code failed to verify", whatAreWeVerifying=whatAreWeVerifying, err=r.error)
    raise newException(CatchableError, "async code failed to verify: " & $(whatAreWeVerifying) & ", error is: " & $(r.error))

const shouldDoUnnecessarySanityChecks = true

# This proc fetches both the account and also optionally some of its slots, because that's what eth_getProof can do.
proc ifNecessaryGetAccountAndSlots*(client: RpcClient, db: CoreDbRef, blockNumber: common.BlockNumber, stateRoot: common.Hash256, address: EthAddress, slots: seq[UInt256], justCheckingAccount: bool, justCheckingSlots: bool, newStateRootForSanityChecking: common.Hash256): Future[void] {.async.} =
  let trie = initAccountsTrie(db, stateRoot, false)  # important for sanity checks
  let trie2 = initAccountsTrie(db, newStateRootForSanityChecking, false)  # important for sanity checks
  let doesAccountActuallyNeedToBeFetched = not trie.hasAllNodesForAccount(address)
  let slotsToActuallyFetch = slots.filter(proc(slot: UInt256): bool = not (trie.hasAllNodesForStorageSlot(address, slot)))
  if (not doesAccountActuallyNeedToBeFetched) and (slotsToActuallyFetch.len == 0):
    # Already have them, no need to fetch either the account or the slots
    discard
  else:
    let (acc, accProof, storageProofs) = await fetchAccountAndSlots(client, address, slotsToActuallyFetch, blockNumber)

    # We need to verify the proof even if we already had this account,
    # to make sure the data is valid.
    let accountVerificationRes = verifyFetchedAccount(stateRoot, address, acc, accProof)
    let whatAreWeVerifying = ("account proof", address, acc)
    raiseExceptionIfError(whatAreWeVerifying, accountVerificationRes)

    if not doesAccountActuallyNeedToBeFetched:
      # We already had the account, no need to populate the DB with it again.
      discard
    else:
      if not justCheckingAccount:
        populateDbWithBranch(db, accProof)
        if shouldDoUnnecessarySanityChecks:
          assertThatWeHaveStoredAccount(trie, address, acc, false)
          if doesAccountActuallyNeedToBeFetched: # this second check makes no sense if it's not the first time
            assertThatWeHaveStoredAccount(trie2, address, acc, true)

    doAssert(slotsToActuallyFetch.len == storageProofs.len, "We should get back the same number of storage proofs as slots that we asked for. I think.")

    for storageProof in storageProofs:
      let slot: UInt256 = storageProof.key
      let fetchedVal: UInt256 = storageProof.value
      let storageMptNodes: seq[seq[byte]] = storageProof.proof.mapIt(distinctBase(it))
      let storageVerificationRes = verifyFetchedSlot(acc.storageRoot, slot, fetchedVal, storageMptNodes)
      let whatAreWeVerifying = ("storage proof", address, acc, slot, fetchedVal)
      raiseExceptionIfError(whatAreWeVerifying, storageVerificationRes)

      if not justCheckingSlots:
        populateDbWithBranch(db, storageMptNodes)

        # I believe this is done so that we can iterate over the slots. See
        # persistStorage in `db/ledger`.
        let slotAsKey = createTrieKeyFromSlot(slot)
        let slotHash = keccakHash(slotAsKey)
        let slotEncoded = rlp.encode(slot)
        db.kvt.put(slotHashToSlotKey(slotHash.data).toOpenArray, slotEncoded)

        if shouldDoUnnecessarySanityChecks:
          assertThatWeHaveStoredSlot(trie, address, acc, slot, fetchedVal, false)
          assertThatWeHaveStoredSlot(trie2, address, acc, slot, fetchedVal, true)

proc ifNecessaryGetCode*(client: RpcClient, db: CoreDbRef, blockNumber: common.BlockNumber, stateRoot: common.Hash256, address: EthAddress, justChecking: bool, newStateRootForSanityChecking: common.Hash256): Future[void] {.async.} =
  await ifNecessaryGetAccountAndSlots(client, db, blockNumber, stateRoot, address, @[], false, false, newStateRootForSanityChecking)  # to make sure we've got the codeHash
  let trie = initAccountsTrie(db, stateRoot, false)  # important for sanity checks

  let acc = ifNodesExistGetAccount(trie, address).get
  let desiredCodeHash = acc.codeHash

  let p = (blockNumber, address)
  if not(trie.hasAllNodesForCode(address)):
    let fetchedCode = await fetchAndVerifyCode(client, p, desiredCodeHash)

    if not justChecking:
      storeCode(trie, p, desiredCodeHash, fetchedCode)
      if shouldDoUnnecessarySanityChecks:
        assertThatWeHaveStoredCode(trie, p, desiredCodeHash)

proc ifNecessaryGetBlockHeaderByNumber*(client: RpcClient, chainDB: CoreDbRef, blockNumber: common.BlockNumber, justChecking: bool): Future[void] {.async.} =
  let maybeHeaderAndHash = chainDB.getBlockHeaderWithHash(blockNumber)
  if maybeHeaderAndHash.isNone:
    let fetchedHeader = await fetchBlockHeaderWithNumber(client, blockNumber)
    let headerVerificationRes = verifyFetchedBlockHeader(fetchedHeader, blockNumber)
    let whatAreWeVerifying = ("block header by number", blockNumber, fetchedHeader)
    raiseExceptionIfError(whatAreWeVerifying, headerVerificationRes)

    if not justChecking:
      storeBlockHeader(chainDB, fetchedHeader)
      if shouldDoUnnecessarySanityChecks:
        assertThatWeHaveStoredBlockHeader(chainDB, blockNumber, fetchedHeader)

# Used in asynchronous on-demand-data-fetching mode.
proc realAsyncDataSource*(peerPool: PeerPool, client: RpcClient, justChecking: bool): AsyncDataSource =
  AsyncDataSource(
    ifNecessaryGetAccount: (proc(db: CoreDbRef, blockNumber: common.BlockNumber, stateRoot: common.Hash256, address: EthAddress, newStateRootForSanityChecking: common.Hash256): Future[void] {.async.} =
      await ifNecessaryGetAccountAndSlots(client, db, blockNumber, stateRoot, address, @[], false, false, newStateRootForSanityChecking)
    ),
    ifNecessaryGetSlots:   (proc(db: CoreDbRef, blockNumber: common.BlockNumber, stateRoot: common.Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: common.Hash256): Future[void] {.async.} =
      await ifNecessaryGetAccountAndSlots(client, db, blockNumber, stateRoot, address, slots, false, false, newStateRootForSanityChecking)
    ),
    ifNecessaryGetCode: (proc(db: CoreDbRef, blockNumber: common.BlockNumber, stateRoot: common.Hash256, address: EthAddress, newStateRootForSanityChecking: common.Hash256): Future[void] {.async.} =
      await ifNecessaryGetCode(client, db, blockNumber, stateRoot, address, justChecking, newStateRootForSanityChecking)
    ),
    ifNecessaryGetBlockHeaderByNumber: (proc(chainDB: CoreDbRef, blockNumber: common.BlockNumber): Future[void] {.async.} =
      await ifNecessaryGetBlockHeaderByNumber(client, chainDB, blockNumber, justChecking)
    ),

    # FIXME-Adam: This will be needed later, but for now let's just get the basic methods in place.
    #fetchNodes: (proc(stateRoot: Hash256, paths: seq[seq[seq[byte]]], nodeHashes: seq[Hash256]): Future[seq[seq[byte]]] {.async.} =
    #  return await fetchNodes(peerPool, stateRoot, paths, nodeHashes)
    #),

    fetchBlockHeaderWithHash: (proc(h: common.Hash256): Future[common.BlockHeader] {.async.} =
      return await fetchBlockHeaderWithHash(client, h)
    ),
    fetchBlockHeaderWithNumber: (proc(n: common.BlockNumber): Future[common.BlockHeader] {.async.} =
      return await fetchBlockHeaderWithNumber(client, n)
    ),
    fetchBlockHeaderAndBodyWithHash: (proc(h: common.Hash256): Future[(common.BlockHeader, BlockBody)] {.async.} =
      return await fetchBlockHeaderAndBodyWithHash(client, h)
    ),
    fetchBlockHeaderAndBodyWithNumber: (proc(n: common.BlockNumber): Future[(common.BlockHeader, BlockBody)] {.async.} =
      return await fetchBlockHeaderAndBodyWithNumber(client, n)
    )
  )
