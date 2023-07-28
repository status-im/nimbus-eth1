import
  std/[sequtils, typetraits, options],
  times,
  chronicles,
  chronos,
  nimcrypto,
  stint,
  stew/byteutils,
  json_rpc/rpcclient,
  eth/common,
  eth/rlp,
  eth/trie/[db, hexary_proof_verification],
  eth/p2p,
  eth/p2p/rlpx,
  eth/p2p/private/p2p_types,
  ../../../sync/protocol,
  ../../../db/[db_chain, distinct_tries, incomplete_db, storage_types],
  ../data_sources

when defined(legacy_eth66_enabled):
  import
    ../../../sync/protocol/eth66 as proto_eth66
  from ../../../sync/protocol/eth66 import getNodeData

from ../../../rpc/rpc_utils import toHash
from web3 import Web3, BlockHash, BlockObject, FixedBytes, Address, ProofResponse, StorageProof, newWeb3, fromJson, fromHex, eth_getBlockByHash, eth_getBlockByNumber, eth_getCode, eth_getProof, blockId, `%`
from web3/ethtypes import Quantity
#from ../../../premix/downloader import request
#from ../../../premix/parser import prefixHex, parseBlockHeader, parseReceipt, parseTransaction

# Trying to do things the new web3 way:
from ../../../nimbus_verified_proxy/validate_proof import getAccountFromProof

export AsyncOperationFactory, AsyncDataSource


var durationSpentDoingFetches*: times.Duration
var fetchCounter*: int


func toHash*(s: string): Hash256 {.raises: [ValueError].} =
  hexToPaddedByteArray[32](s).toHash

func toHash*(h: BlockHash): Hash256 {.raises: [].} =
  distinctBase(h).toHash

func toWeb3BlockHash*(h: Hash256): BlockHash =
  BlockHash(h.data)

func web3AddressToEthAddress(a: web3.Address): EthAddress =
  distinctBase(a)


proc makeAnRpcClient*(web3Url: string): Future[RpcClient] {.async.} =
  let myWeb3: Web3 = waitFor(newWeb3(web3Url))
  return myWeb3.provider


#[
  BlockObject* = ref object
    number*: Quantity                 # the block number. null when its pending block.
    hash*: Hash256                    # hash of the block. null when its pending block.
    parentHash*: Hash256              # hash of the parent block.
    sha3Uncles*: Hash256              # SHA3 of the uncles data in the block.
    logsBloom*: FixedBytes[256]       # the bloom filter for the logs of the block. null when its pending block.
    transactionsRoot*: Hash256        # the root of the transaction trie of the block.
    stateRoot*: Hash256               # the root of the final state trie of the block.
    receiptsRoot*: Hash256            # the root of the receipts trie of the block.
    miner*: Address                   # the address of the beneficiary to whom the mining rewards were given.
    difficulty*: UInt256              # integer of the difficulty for this block.
    extraData*: DynamicBytes[0, 32]   # the "extra data" field of this block.
    gasLimit*: Quantity               # the maximum gas allowed in this block.
    gasUsed*: Quantity                # the total used gas by all transactions in this block.
    timestamp*: Quantity              # the unix timestamp for when the block was collated.
    nonce*: Option[FixedBytes[8]]     # hash of the generated proof-of-work. null when its pending block.
    size*: Quantity                   # integer the size of this block in bytes.
    totalDifficulty*: UInt256         # integer of the total difficulty of the chain until this block.
    transactions*: seq[TxHash]        # list of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
    uncles*: seq[Hash256]             # list of uncle hashes.
    baseFeePerGas*: Option[UInt256]   # EIP-1559
    withdrawalsRoot*: Option[Hash256] # EIP-4895
    excessBlobGas*:   Option[UInt256] # EIP-4844
]#

func fromQty(x: Option[Quantity]): Option[uint64] =
  if x.isSome:
    some(x.get().uint64)
  else:
    none(uint64)

func blockHeaderFromBlockObject(o: BlockObject): BlockHeader =
  let nonce: BlockNonce = if o.nonce.isSome: distinctBase(o.nonce.get) else: default(BlockNonce)
  BlockHeader(
    parentHash: o.parentHash.toHash,
    ommersHash: o.sha3Uncles.toHash,
    coinbase: o.miner.web3AddressToEthAddress,
    stateRoot: o.stateRoot.toHash,
    txRoot: o.transactionsRoot.toHash,
    receiptRoot: o.receiptsRoot.toHash,
    bloom: distinctBase(o.logsBloom),
    difficulty: o.difficulty,
    blockNumber: distinctBase(o.number).u256,
    gasLimit: int64(distinctBase(o.gasLimit)),
    gasUsed: int64(distinctBase(o.gasUsed)),
    timestamp: initTime(int64(distinctBase(o.timestamp)), 0),
    extraData: distinctBase(o.extraData),
    #mixDigest: o.mixHash.toHash, # AARDVARK what's this?
    nonce: nonce,
    fee: o.baseFeePerGas,
    withdrawalsRoot: o.withdrawalsRoot.map(toHash),
    blobGasUsed: fromQty(o.blobGasUsed),
    excessBlobGas: fromQty(o.excessBlobGas)
  )

proc fetchBlockHeaderWithHash*(rpcClient: RpcClient, h: Hash256): Future[BlockHeader] {.async.} =
  let t0 = now()
  let blockObject: BlockObject = await rpcClient.eth_getBlockByHash(h.toWeb3BlockHash, false)
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return blockHeaderFromBlockObject(blockObject)

proc fetchBlockHeaderWithNumber*(rpcClient: RpcClient, n: BlockNumber): Future[BlockHeader] {.async.} =
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
    let uncleHash: Hash256 = un.getStr.toHash
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

proc fetchBlockHeaderAndBodyWithHash*(rpcClient: RpcClient, h: Hash256): Future[(BlockHeader, BlockBody)] {.async.} =
  doAssert(false, "AARDVARK not implemented")

proc fetchBlockHeaderAndBodyWithNumber*(rpcClient: RpcClient, n: BlockNumber): Future[(BlockHeader, BlockBody)] {.async.} =
  doAssert(false, "AARDVARK not implemented")

func mdigestFromFixedBytes*(arg: FixedBytes[32]): MDigest[256] =
  MDigest[256](data: distinctBase(arg))

func mdigestFromString*(s: string): MDigest[256] =
  mdigestFromFixedBytes(FixedBytes[32].fromHex(s))

type
  AccountProof* = seq[seq[byte]]

proc fetchAccountAndSlots*(rpcClient: RpcClient, address: EthAddress, slots: seq[UInt256], blockNumber: BlockNumber): Future[(Account, AccountProof, seq[StorageProof])] {.async.} =
  let t0 = now()
  debug "Got to fetchAccountAndSlots", address=address, slots=slots, blockNumber=blockNumber
  #let blockNumberHexStr: HexQuantityStr = encodeQuantity(blockNumber)
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

proc fetchCode*(client: RpcClient, blockNumber: BlockNumber, address: EthAddress): Future[seq[byte]] {.async.} =
  let t0 = now()
  let a = web3.Address(address)
  let bid = blockId(blockNumber.truncate(uint64))
  let fetchedCode: seq[byte] = await client.eth_getCode(a, bid)
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  return fetchedCode

const bytesLimit = 2 * 1024 * 1024
const maxNumberOfPeersToAttempt = 3

proc fetchUsingGetTrieNodes(peer: Peer, stateRoot: Hash256, paths: seq[SnapTriePaths]): Future[seq[seq[byte]]] {.async.} =
  let r = await peer.getTrieNodes(stateRoot, paths, bytesLimit)
  if r.isNone:
    raise newException(CatchableError, "AARDVARK: received None in GetTrieNodes response")
  else:
    return r.get.nodes

proc fetchUsingGetNodeData(peer: Peer, nodeHashes: seq[Hash256]): Future[seq[seq[byte]]] {.async.} =
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

proc findPeersAndMakeSomeCalls[R](peerPool: PeerPool, protocolName: string, protocolType: typedesc, initiateAttempt: (proc(p: Peer): Future[R] {.gcsafe.})): Future[seq[Future[R]]] {.async.} =
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
      await sleepAsync(5000)
    else:
      if attempts.len < maxNumberOfPeersToAttempt:
        warn("AARDVARK: findPeersAndMakeSomeCalls did not find enough peers, but found some", protocolName, totalPeerPoolSize=peerPool.connectedNodes.len, found=attempts.len)
      break
  return attempts

proc findPeersAndMakeSomeAttemptsToCallGetTrieNodes(peerPool: PeerPool, stateRoot: Hash256, paths: seq[SnapTriePaths]): Future[seq[Future[seq[seq[byte]]]]] =
  findPeersAndMakeSomeCalls(peerPool, "snap", protocol.snap, (proc(peer: Peer): Future[seq[seq[byte]]] = fetchUsingGetTrieNodes(peer, stateRoot, paths)))

#[
proc findPeersAndMakeSomeAttemptsToCallGetNodeData(peerPool: PeerPool, stateRoot: Hash256, nodeHashes: seq[Hash256]): Future[seq[Future[seq[seq[byte]]]]] =
  findPeersAndMakeSomeCalls(peerPool, "eth66", eth66, (proc(peer: Peer): Future[seq[seq[byte]]] = fetchUsingGetNodeData(peer, nodeHashes)))
]#

proc fetchNodes(peerPool: PeerPool, stateRoot: Hash256, paths: seq[SnapTriePaths], nodeHashes: seq[Hash256]): Future[seq[seq[byte]]] {.async.} =
  let attempts = await findPeersAndMakeSomeAttemptsToCallGetTrieNodes(peerPool, stateRoot, paths)
  #let attempts = await findPeersAndMakeSomeAttemptsToCallGetNodeData(peerPool, stateRoot, nodeHashes)
  let completedAttempt = await one(attempts)
  let nodes: seq[seq[byte]] = completedAttempt.read
  info("AARDVARK: fetchNodes received nodes", nodes)
  return nodes

proc verifyFetchedAccount(stateRoot: Hash256, address: EthAddress, acc: Account, accProof: seq[seq[byte]]): Result[void, string] =
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
  CodeFetchingInfo = tuple[blockNumber: BlockNumber, address: EthAddress]

proc fetchCode(client: RpcClient, p: CodeFetchingInfo): Future[seq[byte]] {.async.} =
  let (blockNumber, address) = p
  let fetchedCode = await fetchCode(client, blockNumber, address)
  return fetchedCode

proc verifyFetchedCode(fetchedCode: seq[byte], desiredCodeHash: Hash256): Result[void, Hash256] =
  let fetchedCodeHash = keccakHash(fetchedCode)
  if desiredCodeHash == fetchedCodeHash:
    ok()
  else:
    err(fetchedCodeHash)

proc fetchAndVerifyCode(client: RpcClient, p: CodeFetchingInfo, desiredCodeHash: Hash256): Future[seq[byte]] {.async.} =
    let fetchedCode: seq[byte] = await fetchCode(client, p)
    let verificationRes = verifyFetchedCode(fetchedCode, desiredCodeHash)
    if verificationRes.isOk():
      return fetchedCode
    else:
      let fetchedCodeHash = verificationRes.error
      error("code hash values do not match", p=p, desiredCodeHash=desiredCodeHash, fetchedCodeHash=fetchedCodeHash)
      raise newException(CatchableError, "async code received code for " & $(p.address) & " whose hash (" & $(fetchedCodeHash) & ") does not match the desired hash (" & $(desiredCodeHash) & ")")

proc putCode*(db: TrieDatabaseRef, codeHash: Hash256, code: seq[byte]) =
  when defined(geth):
    db.put(codeHash.data, code)
  else:
    db.put(contractHashKey(codeHash).toOpenArray, code)

proc putCode*(trie: AccountsTrie, codeHash: Hash256, code: seq[byte]) =
  putCode(distinctBase(trie).db, codeHash, code)

proc storeCode(trie: AccountsTrie, p: CodeFetchingInfo, desiredCodeHash: Hash256, fetchedCode: seq[byte]) =
  trie.putCode(desiredCodeHash, fetchedCode)

proc assertThatWeHaveStoredCode(trie: AccountsTrie, p: CodeFetchingInfo, codeHash: Hash256) =
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


proc verifyFetchedSlot(accountStorageRoot: Hash256, slot: UInt256, fetchedVal: UInt256, storageMptNodes: seq[seq[byte]]): Result[void, string] =
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


proc assertThatWeHaveStoredSlot(trie: AccountsTrie, address: EthAddress, acc: Account, slot: UInt256, fetchedVal: UInt256, isForTheNewTrie: bool = false) =
  if acc.storageRoot == EMPTY_ROOT_HASH and fetchedVal.isZero:
    # I believe this is okay.
    discard
  else:
    let foundVal = ifNodesExistGetStorage(trie, address, slot).get
    if (fetchedVal != foundVal):
      error("slot didn't come out the same", address=address, slot=slot, fetchedVal=fetchedVal, foundVal=foundVal, isForTheNewTrie=isForTheNewTrie)
      doAssert false, "slot didn't come out the same"


proc verifyFetchedBlockHeader(fetchedHeader: BlockHeader, desiredBlockNumber: BlockNumber): Result[void, BlockNumber] =
  # *Can* we do anything to verify this header, given that all we know
  # is the desiredBlockNumber and we want to run statelessly so we don't
  # know what block hash we want?
  ok()

proc storeBlockHeader(chainDB: ChainDBRef, header: BlockHeader) =
  chainDB.persistHeaderToDbWithoutSetHeadOrScore(header)

proc assertThatWeHaveStoredBlockHeader(chainDB: ChainDBRef, blockNumber: BlockNumber, header: BlockHeader) =
  let h = chainDB.getBlockHash(blockNumber)
  doAssert(h == header.blockHash, "stored the block header for block " & $(blockNumber))

proc raiseExceptionIfError[V, E](whatAreWeVerifying: V, r: Result[void, E]) =
  if r.isErr:
    error("async code failed to verify", whatAreWeVerifying=whatAreWeVerifying, err=r.error)
    raise newException(CatchableError, "async code failed to verify: " & $(whatAreWeVerifying) & ", error is: " & $(r.error))

const shouldDoUnnecessarySanityChecks = true

# This proc fetches both the account and also optionally some of its slots, because that's what eth_getProof can do.
proc ifNecessaryGetAccountAndSlots*(client: RpcClient, db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], justCheckingAccount: bool, justCheckingSlots: bool, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
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
        # persistStorage in accounts_cache.nim.
        let slotAsKey = createTrieKeyFromSlot(slot)
        let slotHash = keccakHash(slotAsKey)
        let slotEncoded = rlp.encode(slot)
        db.put(slotHashToSlotKey(slotHash.data).toOpenArray, slotEncoded)

        if shouldDoUnnecessarySanityChecks:
          assertThatWeHaveStoredSlot(trie, address, acc, slot, fetchedVal, false)
          assertThatWeHaveStoredSlot(trie2, address, acc, slot, fetchedVal, true)

proc ifNecessaryGetCode*(client: RpcClient, db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, justChecking: bool, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
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

proc ifNecessaryGetBlockHeaderByNumber*(client: RpcClient, chainDB: ChainDBRef, blockNumber: BlockNumber, justChecking: bool): Future[void] {.async.} =
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
    ifNecessaryGetAccount: (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
      await ifNecessaryGetAccountAndSlots(client, db, blockNumber, stateRoot, address, @[], false, false, newStateRootForSanityChecking)
    ),
    ifNecessaryGetSlots:   (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
      await ifNecessaryGetAccountAndSlots(client, db, blockNumber, stateRoot, address, slots, false, false, newStateRootForSanityChecking)
    ),
    ifNecessaryGetCode: (proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
      await ifNecessaryGetCode(client, db, blockNumber, stateRoot, address, justChecking, newStateRootForSanityChecking)
    ),
    ifNecessaryGetBlockHeaderByNumber: (proc(chainDB: ChainDBRef, blockNumber: BlockNumber): Future[void] {.async.} =
      await ifNecessaryGetBlockHeaderByNumber(client, chainDB, blockNumber, justChecking)
    ),

    # FIXME-Adam: This will be needed later, but for now let's just get the basic methods in place.
    #fetchNodes: (proc(stateRoot: Hash256, paths: seq[seq[seq[byte]]], nodeHashes: seq[Hash256]): Future[seq[seq[byte]]] {.async.} =
    #  return await fetchNodes(peerPool, stateRoot, paths, nodeHashes)
    #),

    fetchBlockHeaderWithHash: (proc(h: Hash256): Future[BlockHeader] {.async.} =
      return await fetchBlockHeaderWithHash(client, h)
    ),
    fetchBlockHeaderWithNumber: (proc(n: BlockNumber): Future[BlockHeader] {.async.} =
      return await fetchBlockHeaderWithNumber(client, n)
    ),
    fetchBlockHeaderAndBodyWithHash: (proc(h: Hash256): Future[(BlockHeader, BlockBody)] {.async.} =
      return await fetchBlockHeaderAndBodyWithHash(client, h)
    ),
    fetchBlockHeaderAndBodyWithNumber: (proc(n: BlockNumber): Future[(BlockHeader, BlockBody)] {.async.} =
      return await fetchBlockHeaderAndBodyWithNumber(client, n)
    )
  )
