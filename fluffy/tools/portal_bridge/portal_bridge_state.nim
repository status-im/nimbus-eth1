# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  stew/byteutils,
  stint,
  eth/[common, trie, trie/db],
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../rpc/rpc_calls/rpc_trace_calls,
  ../../../nimbus/common/chain_config,
  ./[portal_bridge_conf, portal_bridge_common]

type
  DiffType = enum
    unchanged
    create
    update
    delete

  Code = seq[byte]
  StateValue = UInt256 | AccountNonce | Code

  StateValueDiff[StateValue] = object
    kind: DiffType
    before: StateValue
    after: StateValue

  StateDiffRef = ref object
    balances*: Table[EthAddress, StateValueDiff[UInt256]]
    nonces*: Table[EthAddress, StateValueDiff[AccountNonce]]
    storage*: Table[EthAddress, Table[UInt256, StateValueDiff[UInt256]]]
    code*: Table[EthAddress, StateValueDiff[Code]]

proc toStateValue(T: type UInt256, hex: string): T {.raises: [CatchableError].} =
  UInt256.fromHex(hex)

proc toStateValue(T: type AccountNonce, hex: string): T {.raises: [CatchableError].} =
  UInt256.fromHex(hex).truncate(uint64)

proc toStateValue(T: type Code, hex: string): T {.raises: [CatchableError].} =
  hexToSeqByte(hex)

proc toStateValueDiff(
    diffJson: JsonNode, T: type StateValue
): StateValueDiff[T] {.raises: [CatchableError].} =
  if diffJson.kind == JString and diffJson.getStr() == "=":
    return StateValueDiff[T](kind: unchanged)
  elif diffJson.kind == JObject:
    if diffJson{"+"} != nil:
      return
        StateValueDiff[T](kind: create, after: T.toStateValue(diffJson{"+"}.getStr()))
    elif diffJson{"-"} != nil:
      return
        StateValueDiff[T](kind: delete, before: T.toStateValue(diffJson{"-"}.getStr()))
    elif diffJson{"*"} != nil:
      return StateValueDiff[T](
        kind: update,
        before: T.toStateValue(diffJson{"*"}{"from"}.getStr()),
        after: T.toStateValue(diffJson{"*"}{"to"}.getStr()),
      )
    else:
      doAssert false # unreachable
  else:
    doAssert false # unreachable

proc toStateDiff(stateDiffJson: JsonNode): StateDiffRef {.raises: [CatchableError].} =
  let stateDiff = StateDiffRef()

  for addrJson, accJson in stateDiffJson.pairs:
    let address = EthAddress.fromHex(addrJson)

    stateDiff.balances[address] = toStateValueDiff(accJson["balance"], UInt256)
    stateDiff.nonces[address] = toStateValueDiff(accJson["nonce"], AccountNonce)
    stateDiff.code[address] = toStateValueDiff(accJson["code"], Code)

    let storageDiff = accJson["storage"]
    var accountStorage: Table[UInt256, StateValueDiff[UInt256]]

    for slotKeyJson, slotValueJson in storageDiff.pairs:
      let slotKey = UInt256.fromHex(slotKeyJson)
      accountStorage[slotKey] = toStateValueDiff(slotValueJson, UInt256)

    stateDiff.storage[address] = accountStorage

  stateDiff

proc toStateDiffs(
    blockTraceJson: JsonNode
): seq[StateDiffRef] {.raises: [CatchableError].} =
  var stateDiffs = newSeqOfCap[StateDiffRef](blockTraceJson.len())
  for blockTrace in blockTraceJson:
    stateDiffs.add(blockTrace["stateDiff"].toStateDiff())

  stateDiffs

proc getUncleBlockByNumberAndIndex*(
    client: RpcClient, blockId: RtBlockIdentifier, index: Quantity
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  let blck =
    try:
      let res = await client.eth_getUncleByBlockNumberAndIndex(blockId, index)
      if res.isNil:
        return err("EL failed to provide requested uncle block")

      res
    except CatchableError as e:
      return err("EL JSON-RPC eth_getUncleByBlockNumberAndIndex failed: " & e.msg)

  return ok(blck)

proc getStateDiffsByBlockNumber(
    client: RpcClient, blockId: RtBlockIdentifier
): Future[Result[seq[StateDiffRef], string]] {.async: (raises: []).} =
  const traceOpts = @["stateDiff"]

  try:
    let blockTraceJson = await client.trace_replayBlockTransactions(blockId, traceOpts)
    if blockTraceJson.isNil:
      return err("EL failed to provide requested state diff")
    ok(blockTraceJson.toStateDiffs())
  except CatchableError as e:
    return err("EL JSON-RPC trace_replayBlockTransactions failed: " & e.msg)

proc getAccountOrDefault(
    accountsTrie: HexaryTrie, addressHash: openArray[byte]
): Account {.raises: [RlpError].} =
  let accountBytes = accountsTrie.get(addressHash)
  if accountBytes.len() == 0:
    newAccount()
  else:
    rlp.decode(accountBytes, Account)

# For now just using in-memory state tries
# To-Do: Use RocksDb as the db backend
# To-Do: Use location based trie implementation where path is used
# instead of node hash is used as key for each value in the trie.
proc toState*(
    alloc: GenesisAlloc
): (HexaryTrie, Table[EthAddress, HexaryTrie]) {.raises: [RlpError].} =
  var accountsTrie = initHexaryTrie(newMemoryDB())
  var storageTries = Table[EthAddress, HexaryTrie]()

  for address, genAccount in alloc:
    var storageRoot = EMPTY_ROOT_HASH
    var codeHash = EMPTY_CODE_HASH

    if genAccount.code.len() > 0:
      var storageTrie = initHexaryTrie(newMemoryDB())
      for slotKey, slotValue in genAccount.storage:
        let key = keccakHash(toBytesBE(slotKey)).data
        let value = rlp.encode(slotValue)
        storageTrie.put(key, value)
      storageTries[address] = storageTrie
      storageRoot = storageTrie.rootHash()
      codeHash = keccakHash(genAccount.code)

    let account = Account(
      nonce: genAccount.nonce,
      balance: genAccount.balance,
      storageRoot: storageRoot,
      codeHash: codeHash,
    )
    let key = keccakHash(address).data
    let value = rlp.encode(account)
    accountsTrie.put(key, value)

  (accountsTrie, storageTries)

proc applyStateUpdates(
    accountsTrie: var HexaryTrie,
    storageTries: var Table[EthAddress, HexaryTrie],
    stateDiff: StateDiffRef,
) {.raises: [RlpError].} =
  if stateDiff == nil:
    return

  # apply state changes
  for address, balanceDiff in stateDiff.balances:
    let
      addressHash = keccakHash(address).data
      nonceDiff = stateDiff.nonces.getOrDefault(address)
        # what happens when the mapping is missing? Do we get unchanged as the default
      codeDiff = stateDiff.code.getOrDefault(address)
      storageDiff = stateDiff.storage.getOrDefault(address)

    var
      deleteAccount = false
      account = accountsTrie.getAccountOrDefault(addressHash)

    if balanceDiff.kind == create or balanceDiff.kind == update:
      account.balance = balanceDiff.after
    elif balanceDiff.kind == delete:
      deleteAccount = true

    if nonceDiff.kind == create or nonceDiff.kind == update:
      account.nonce = nonceDiff.after
    elif nonceDiff.kind == delete:
      doAssert deleteAccount == true # should already be set to true from balanceDiff

    if codeDiff.kind == create or codeDiff.kind == update:
      account.codeHash = keccakHash(codeDiff.after) # TODO: store code in db
    elif codeDiff.kind == delete:
      doAssert deleteAccount == true # should already be set to true from balanceDiff

    var storageTrie = storageTries.getOrDefault(address, initHexaryTrie(newMemoryDB()))

    for slotKey, slotDiff in storageDiff:
      let slotHash = keccakHash(toBytesBE(slotKey)).data

      if slotDiff.kind == create or slotDiff.kind == update:
        if slotDiff.after == 0:
          storageTrie.del(slotHash)
        else:
          storageTrie.put(slotHash, rlp.encode(slotDiff.after))
      elif slotDiff.kind == delete:
        storageTrie.del(slotHash)

    account.storageRoot = storageTrie.rootHash()
    storageTries[address] = storageTrie

    if deleteAccount:
      accountsTrie.del(addressHash)
      storageTries.del(address)
      # TODO: delete the code
    else:
      accountsTrie.put(addressHash, rlp.encode(account))

proc applyBlockRewards(
    accountsTrie: var HexaryTrie,
    blockObject: BlockObject,
    uncleBlocks: openArray[BlockObject],
) {.raises: [RlpError].} =
  const baseReward = 5.u256 * pow(10.u256, 18)

  block:
    # calculate block miner reward
    let blockMinerAddrHash = keccakHash(blockObject.miner.EthAddress).data
    var account = accountsTrie.getAccountOrDefault(blockMinerAddrHash)
    account.balance += baseReward + (baseReward shr 5) * uncleBlocks.len().u256
    accountsTrie.put(blockMinerAddrHash, rlp.encode(account))

  # calculate uncle miners rewards
  for i, uncleBlock in uncleBlocks:
    let uncleMinerAddrHash = keccakHash(uncleBlock.miner.EthAddress).data
    var account = accountsTrie.getAccountOrDefault(uncleMinerAddrHash)
    account.balance +=
      ((8 + uncleBlock.number.uint64 - blockObject.number.uint64).u256 * baseReward) shr
      3
    accountsTrie.put(uncleMinerAddrHash, rlp.encode(account))

proc runBackfillLoop(
    #portalClient: RpcClient,
    web3Client: RpcClient,
    startBlockNumber: uint64,
) {.async: (raises: [CancelledError]).} =
  var currentBlockNumber = 1.uint64
    # for now we can only start from block 1 because the state is only in memory
  echo "Starting from block number: ", currentBlockNumber

  try:
    let
      genesisAccounts = genesisBlockForNetwork(MainNet).alloc
      blockZero = (await web3Client.getBlockByNumber(blockId(0), false)).get()
    var (accountsTrie, storageTries) = toState(genesisAccounts)
    # verify the genesis state root
    # TODO: remove this later
    doAssert blockZero.stateRoot.bytes() == accountsTrie.rootHash.data
    discard blockZero

    while true:
      # TODO: can probably batch requests in parellel in order to improve performance
      # so that processing the state can be done while waiting for network io
      let
        blockNumRequest =
          web3Client.getBlockByNumber(blockId(currentBlockNumber), false)
        stateDiffsRequest =
          web3Client.getStateDiffsByBlockNumber(blockId(currentBlockNumber))

        blockObject = (await blockNumRequest).valueOr:
          error "Failed to get block", error
          await sleepAsync(1.seconds)
          continue

      var uncleBlocks: seq[BlockObject]
      for i in 0 .. blockObject.uncles.high:
        let uncleBlock = (
          await web3Client.getUncleBlockByNumberAndIndex(
            blockId(currentBlockNumber), i.Quantity
          )
        ).valueOr:
          error "Failed to get uncle block", error
          await sleepAsync(1.seconds)
          continue
        uncleBlocks.add(uncleBlock)

      let stateDiffs = (await stateDiffsRequest).valueOr:
        error "Failed to get state diff", error
        await sleepAsync(1.seconds)
        continue
      # if currentBlockNumber == 54319:
      #   for stateDiff in stateDiffs:
      #     echo "stateDiff.balances:", stateDiff.balances
      #     echo "stateDiff.nonces:", stateDiff.nonces
      #     echo "stateDiff.storage:", stateDiff.storage
      #     echo "stateDiff.code:", stateDiff.code

      if currentBlockNumber mod 1000 == 0:
        echo "Current block number: ", currentBlockNumber
      # echo "block number: ", blockObject.number.uint64
      # echo "block stateRoot: ", blockObject.stateRoot
      # echo "block uncles: ", blockObject.uncles

      for stateDiff in stateDiffs:
        applyStateUpdates(accountsTrie, storageTries, stateDiff)
      applyBlockRewards(accountsTrie, blockObject, uncleBlocks)

      # echo "calculated stateRoot: ", accountsTrie.rootHash
      doAssert(blockObject.stateRoot.bytes() == accountsTrie.rootHash.data)

      inc currentBlockNumber
  except CatchableError as e:
    error "runBackfillLoop failed: ", error = e.msg

proc runState*(config: PortalBridgeConf) =
  let
    #portalClient = newRpcClientConnect(config.portalRpcUrl)
    web3Client = newRpcClientConnect(config.web3UrlState)

  # TODO:
  # Here we'd want to implement initially a loop that backfills the state
  # content. Secondly, a loop that follows the head and injects the latest
  # state changes too.
  #
  # The first step would probably be the easier one to start with, as one
  # can start from genesis state.
  # It could be implemented by using the `exp_getProofsByBlockNumber` JSON-RPC
  # method from nimbus-eth1.
  # It could also be implemented by having the whole state execution happening
  # inside the bridge, and getting the blocks from era1 files.

  if config.backfillState:
    asyncSpawn runBackfillLoop(web3Client, config.startBlockNumber)

  while true:
    poll()
