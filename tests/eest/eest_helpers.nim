# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[json, strutils],
  eth/common/headers_rlp,
  web3/eth_api_types,
  web3/engine_api_types,
  web3/primitives,
  web3/conversions,
  web3/execution_types,
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  ./chain_config_wrapper,
  ../../execution_chain/rpc,
  ../../execution_chain/common/hardforks,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/common/common,
  ../../hive_integration/nodocker/engine/engine_client

import ../../tools/common/helpers as chp except HardFork
import ../../tools/evmstate/helpers except HardFork

# Common Type Definitions
type
  GenesisHeader* = object
    parentHash: Hash32
    uncleHash: Hash32
    coinbase: Address
    stateRoot*: Hash32
    transactionsTrie: Hash32
    receiptTrie: Hash32
    bloom: Bytes256
    difficulty: UInt256
    number: Quantity
    gasLimit: Quantity
    gasUsed: Quantity
    timestamp: Quantity
    extraData: HistoricExtraData
    mixHash: Bytes32
    nonce: Bytes8
    baseFeePerGas: Opt[UInt256]
    withdrawalsRoot: Opt[Hash32]
    blobGasUsed: Opt[Quantity]
    excessBlobGas: Opt[Quantity]
    parentBeaconBlockRoot: Opt[Hash32]
    requestsHash: Opt[Hash32]
    hash*: Hash32

  BlockDesc* = object
    blk*: EthBlock
    badBlock*: bool

  Numero* = distinct uint64

  PayloadParam* = object
    payload*: ExecutionPayload
    versionedHashes*: Opt[seq[Hash32]]
    parentBeaconBlockRoot*: Opt[Hash32]
    excutionRequests*: Opt[seq[seq[byte]]]

  PayloadItem* = object
    params*: PayloadParam
    newPayloadVersion*: Numero
    forkchoiceUpdatedVersion*: Numero

  EnvConfig* = object
    network*: string
    chainid*: UInt256
    blobSchedule*: array[HardFork.Cancun..HardFork.high, Opt[BlobSchedule]]

  UnitEnv* = object of RootObj
    network*: string
    genesisBlockHeader*: GenesisHeader
    pre*: JsonNode
    postState*: JsonNode
    lastblockhash*: Hash32
    config*: EnvConfig

  TestEnv* = ref object
    chain*: ForkedChainRef
    server*: Opt[RpcHttpServer]
    client*: Opt[RpcHttpClient]

  ## Blockchain Test Types
  BlockchainUnitEnv* = object of UnitEnv
    blocks*: JsonNode
  
  BlockchainUnitDesc* = object
    name*: string
    unit*: BlockchainUnitEnv

  BlockchainFixture* = object
    units*: seq[BlockchainUnitDesc]

  ## Engine Test Types
  EngineUnitEnv* = object of UnitEnv
    engineNewPayloads*: seq[PayloadItem]

  EngineUnitDesc* = object
    name*: string
    unit*: EngineUnitEnv

  EngineFixture* = object
    units*: seq[EngineUnitDesc]

GenesisHeader.useDefaultReaderIn JrpcConv
PayloadItem.useDefaultReaderIn JrpcConv
EngineUnitEnv.useDefaultReaderIn JrpcConv
BlockchainUnitEnv.useDefaultReaderIn JrpcConv
EnvConfig.useDefaultReaderIn JrpcConv
BlobSchedule.useDefaultReaderIn JrpcConv

template wrapValueError(body: untyped) =
  try:
    body
  except ValueError as exc:
    r.raiseUnexpectedValue(exc.msg)

proc readValue*(r: var JsonReader[JrpcConv], val: var Numero)
       {.gcsafe, raises: [IOError, SerializationError].} =
  wrapValueError:
    val = fromHex[uint64](r.readValue(string)).Numero

proc readValue*(r: var JsonReader[JrpcConv], value: var array[HardFork.Cancun..HardFork.high, Opt[BlobSchedule]])
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapValueError:
    for key in r.readObjectFields:
      blobScheduleParser(r, key, value)

proc readValue*(r: var JsonReader[JrpcConv], val: var PayloadParam)
       {.gcsafe, raises: [IOError, SerializationError].} =
  wrapValueError:
    r.parseArray(i):
      case i
      of 0: r.readValue(val.payload)
      of 1: r.readValue(val.versionedHashes)
      of 2: r.readValue(val.parentBeaconBlockRoot)
      of 3: r.readValue(val.excutionRequests)
      else:
        r.raiseUnexpectedValue("Unexpected element")

proc readValue*(r: var JsonReader[JrpcConv], val: var EngineFixture)
       {.gcsafe, raises: [IOError, SerializationError].} =
  wrapValueError:
    parseObject(r, key):
      val.units.add EngineUnitDesc(
        name: key,
        unit: r.readValue(EngineUnitEnv)
      )

proc readValue*(r: var JsonReader[JrpcConv], val: var BlockchainFixture)
       {.gcsafe, raises: [IOError, SerializationError].} =
  wrapValueError:
    parseObject(r, key):
      val.units.add BlockchainUnitDesc(
        name: key,
        unit: r.readValue(BlockchainUnitEnv)
      )

func to*(x: Opt[Quantity], _: type Opt[uint64]): Opt[uint64] =
  if x.isSome:
    Opt.some(x.value.uint64)
  else:
    Opt.none(uint64)

func to*(g: GenesisHeader, _: type Header): Header =
  Header(
    parentHash: g.parentHash,
    ommersHash: g.uncleHash,
    coinbase: g.coinbase,
    stateRoot: g.stateRoot,
    transactionsRoot: g.transactionsTrie,
    receiptsRoot: g.receiptTrie,
    logsBloom: g.bloom,
    difficulty: g.difficulty,
    number: g.number.uint64,
    gasLimit: g.gasLimit.GasInt,
    gasUsed: g.gasUsed.GasInt,
    timestamp: g.timestamp.EthTime,
    extraData: g.extraData.data,
    mixHash: g.mixHash,
    nonce: g.nonce,
    baseFeePerGas: g.baseFeePerGas,
    withdrawalsRoot: g.withdrawalsRoot,
    blobGasUsed: g.blobGasUsed.to(Opt[uint64]),
    excessBlobGas: g.excessBlobGas.to(Opt[uint64]),
    parentBeaconBlockRoot: g.parentBeaconBlockRoot,
    requestsHash: g.requestsHash
  )

proc setupClient*(port: Port): RpcHttpClient =
  try:
    let client = newRpcHttpClient()
    waitFor client.connect("127.0.0.1", port, false)
    return client
  except CatchableError as exc:
    debugEcho "CONNECT ERROR: ", exc.msg
    quit(QuitFailure)

proc prepareEnv*(unit: UnitEnv, genesis: Header, rpcEnabled: bool = false): TestEnv =
  try:
    let
      memDB  = newCoreDbRef DefaultDbMemory
      ledger = LedgerRef.init(memDB.baseTxFrame())
      config = getChainConfig(unit.network)

    config.chainId = unit.config.chainid
    config.blobSchedule = unit.config.blobSchedule

    setupLedger(unit.pre, ledger)
    ledger.persist()

    ledger.txFrame.persistHeaderAndSetHead(genesis).isOkOr:
      debugEcho "Failed to put genesis header into database: ", error
      return

    var testEnv = TestEnv()

    let
      com    = CommonRef.new(memDB, nil, config)
      chain  = ForkedChainRef.init(com, enableQueue = true, persistBatchSize = 0)

    testEnv.chain = chain
    testEnv.client = Opt.none(RpcHttpClient)
    testEnv.server = Opt.none(RpcHttpServer)

    if rpcEnabled:
      let
        txPool = TxPoolRef.new(chain)
        server = newRpcHttpServerWithParams("127.0.0.1:7717").valueOr:
          echo "Failed to create rpc server: ", error
          quit(QuitFailure)
        beaconEngine = BeaconEngineRef.new(txPool)
        serverApi = newServerAPI(txPool)

      setupServerAPI(serverApi, server, newEthContext())
      setupEngineAPI(beaconEngine, server)

      server.start()

      let
        client = setupClient(server.localAddress[0].port)

      testEnv.client = Opt.some(client)
      testEnv.server = Opt.some(server)

    return testEnv

  except ValueError as exc:
    debugEcho "Prepare env error: ", exc.msg
    quit(QuitFailure)

proc close*(env: TestEnv) =
  try:
    if env.client.isSome:
      waitFor env.client.get().close()
    if env.server.isSome:
      waitFor env.server.get().closeWait()
    waitFor env.chain.stopProcessingQueue()
  except CatchableError as exc:
    debugEcho "Close error: ", exc.msg
    quit(QuitFailure)

template parseAnyFixture(fileName: string, T: typedesc) =
  try:
    result = JrpcConv.loadFile(fileName, T)
  except JsonReaderError as exc:
    debugEcho exc.formatMsg(fileName)
    quit(QuitFailure)
  except IOError as exc:
    debugEcho "IO ERROR: ", exc.msg
    quit(QuitFailure)
  except SerializationError as exc:
    debugEcho "Serialization error: ", exc.msg
    quit(QuitFailure)

proc parseFixture*(fileName: string, _: type EngineFixture): EngineFixture =
  parseAnyFixture(fileName, EngineFixture)

proc parseFixture*(fileName: string, _: type BlockchainFixture): BlockchainFixture =
  parseAnyFixture(fileName, BlockchainFixture)