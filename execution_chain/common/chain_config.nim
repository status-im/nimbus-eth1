# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[tables, strutils, times, macros],
  eth/[rlp, p2p], eth/common/eth_types_json_serialization,
  eth/common/eth_types_rlp,
  stint, stew/[byteutils],
  json_serialization, chronicles,
  json_serialization/stew/results,
  json_serialization/lexer,
  "."/[genesis_alloc, hardforks]

export
  tables, hardforks

type
  Genesis* = ref object
    nonce*      : Bytes8
    timestamp*  : EthTime
    extraData*  : seq[byte]
    gasLimit*   : GasInt
    difficulty* : DifficultyInt
    mixHash*    : Bytes32
    coinbase*   : Address
    alloc*      : GenesisAlloc
    number*     : BlockNumber
    gasUser*    : GasInt
    parentHash* : Hash32
    baseFeePerGas*: Opt[UInt256]   # EIP-1559
    blobGasUsed*  : Opt[uint64]    # EIP-4844
    excessBlobGas*: Opt[uint64]    # EIP-4844
    parentBeaconBlockRoot*: Opt[Hash32]   # EIP-4788

  GenesisAlloc* = Table[Address, GenesisAccount]
  GenesisStorage* = Table[UInt256, UInt256]
  GenesisAccount* = object
    code*   : seq[byte]
    storage*: GenesisStorage
    balance*: UInt256
    nonce*  : AccountNonce

  NetworkParams* = object
    config* : ChainConfig
    genesis*: Genesis

  Address = addresses.Address

const
  CustomNet*  = 0.NetworkId
  # these are public network id
  MainNet*    = 1.NetworkId
  SepoliaNet* = 11155111.NetworkId
  HoleskyNet* = 17000.NetworkId

createJsonFlavor JGenesis,
  automaticObjectSerialization = false,
  requireAllFields = false,
  omitOptionalFields = true,
  allowUnknownFields = true,
  skipNullFields = true

NetworkParams.useDefaultReaderIn JGenesis
GenesisAccount.useDefaultReaderIn JGenesis
Genesis.useDefaultReaderIn JGenesis
ChainConfig.useDefaultReaderIn JGenesis
BlobSchedule.useDefaultReaderIn JGenesis

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

# used by chronicles json writer
proc writeValue(writer: var JsonWriter, value: Opt[EthTime])
     {.gcsafe, raises: [IOError].} =
  mixin writeValue

  if value.isSome:
    writer.writeValue value.get.uint64
  else:
    writer.writeValue JsonString("null")

type
  Slots = object
    key: UInt256
    val: UInt256

  Misc = object
    nonce: uint64
    code : seq[byte]
    storage: seq[Slots]

  AddressBalance = object
    address: Address
    account: GenesisAccount

proc read*(rlp: var Rlp, T: type AddressBalance): T {.gcsafe, raises: [RlpError].}=
  let listLen = rlp.listLen
  rlp.tryEnterList()
  let abytes = rlp.read(UInt256).to(Bytes32)
  result.address = abytes.to(Address)
  result.account.balance = rlp.read(UInt256)
  if listLen == 3:
    var misc = rlp.read(Misc)
    result.account.nonce = misc.nonce
    result.account.code  = system.move(misc.code)
    for x in misc.storage:
      result.account.storage[x.key] = x.val

proc append*(w: var RlpWriter, ab: AddressBalance) =
  var listLen = 2
  if ab.account.storage.len > 0 or
    ab.account.nonce != 0.AccountNonce or
    ab.account.code.len > 0:
    inc listLen

  w.startList(listLen)
  w.append(ab.address.to(Bytes32).to(UInt256))
  w.append(ab.account.balance)
  if listLen == 3:
    var misc: Misc
    misc.nonce = ab.account.nonce
    misc.code = ab.account.code
    for k, v in ab.account.storage:
      misc.storage.add Slots(key:k, val: v)
    w.append(misc)

proc append*(w: var RlpWriter, ga: GenesisAlloc) =
  var list: seq[AddressBalance]
  for k, v in ga:
    list.add AddressBalance(
      address: k, account: v
    )
  w.append(list)

func decodePrealloc*(data: seq[byte]): GenesisAlloc
    {.gcsafe, raises: [RlpError].} =
  for tup in rlp.decode(data, seq[AddressBalance]):
    result[tup.address] = tup.account

# borrowed from `lexer.hexCharValue()` :)
func fromHex(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

template wrapError(body: untyped) =
  try:
    body
  except ValueError as ex:
    raiseUnexpectedValue(reader, ex.msg)

proc readValue(reader: var JsonReader[JGenesis], value: var UInt256)
    {.gcsafe, raises: [SerializationError, IOError].} =
  ## Mixin for `JGenesis.loadFile()`. Note that this driver applies the same
  ## to `BlockNumber` fields as well as generic `UInt265` fields like the
  ## account `balance`.
  var (accu, ok) = (0.u256, true)
  let tokKind = reader.tokKind
  if tokKind == JsonValueKind.Number:
    try:
      reader.customIntValueIt:
        accu = accu * 10 + it.u256
    except CatchableError:
      ok = false
  elif tokKind == JsonValueKind.String:
    try:
      var (sLen, base) = (0, 10)
      reader.customStringValueIt:
        if ok:
          var num = it.fromHex
          if base <= num:
            ok = false # cannot be larger than base
          elif sLen < 2:
            if 0 <= num:
              accu = accu * base.u256 + num.u256
            elif sLen == 1 and it in {'x', 'X'}:
              base = 16 # handle "0x" prefix
            else:
              ok = false
            sLen.inc
          elif num < 0:
            ok = false # not a hex digit
          elif base == 10:
            accu = accu * 10 + num.u256
          else:
            accu = accu * 16 + num.u256
    except CatchableError:
      reader.raiseUnexpectedValue("numeric string parse error")
  else:
    reader.raiseUnexpectedValue("expect int or hex/int string")
  if not ok:
    reader.raiseUnexpectedValue("Uint256 parse error")
  value = accu

proc readValue(reader: var JsonReader[JGenesis], value: var ChainId)
    {.gcsafe, raises: [SerializationError, IOError].} =
  value = reader.readValue(int).ChainId

proc readValue(reader: var JsonReader[JGenesis], value: var Hash32)
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    value = Hash32.fromHex(reader.readValue(string))

proc readValue(reader: var JsonReader[JGenesis], value: var Bytes8)
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    value = fromHex[uint64](reader.readValue(string)).to(Bytes8)

# genesis timestamp is in hex/dec
proc readValue(reader: var JsonReader[JGenesis], value: var EthTime)
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    let data = reader.readValue(string)
    if data.len > 2 and data[1] == 'x':
      value = fromHex[int64](data).EthTime
    else:
      # TODO: use safer uint64 parser
      value = parseInt(data).EthTime

# but shanghaiTime and cancunTime in config is in int literal
proc readValue(reader: var JsonReader[JGenesis], value: var Opt[EthTime])
    {.gcsafe, raises: [IOError, JsonReaderError].} =
  if reader.tokKind == JsonValueKind.Null:
    reset value
    reader.parseNull()
  else:
    # both readValue(GasInt/AccountNonce) will be called if
    # we use readValue(int64/uint64)
    let val = EthTime reader.parseInt(uint64)
    value = Opt.some val

proc readValue(reader: var JsonReader[JGenesis], value: var seq[byte])
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    value = hexToSeqByte(reader.readValue(string))

proc readValue(reader: var JsonReader[JGenesis], value: var Address)
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    value = Address.fromHex(reader.readValue(string))

proc readValue(reader: var JsonReader[JGenesis], value: var uint64)
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    if reader.tokKind == JsonValueKind.Number:
      value = reader.parseInt(uint64)
    else:
      let data = reader.readValue(string)
      if data.len > 2 and data[1] == 'x':
        value = fromHex[uint64](data)
      else:
        # TODO: use safer uint64 parser
        value = parseInt(data).uint64

proc readValue(reader: var JsonReader[JGenesis], value: var GenesisStorage)
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    for key in reader.readObjectFields:
      value[UInt256.fromHex(key)] = reader.readValue(UInt256)

proc readValue(reader: var JsonReader[JGenesis], value: var GenesisAlloc)
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    for key in reader.readObjectFields:
      value[Address.fromHex(key)] = reader.readValue(GenesisAccount)

const
  BlobScheduleTable: array[Cancun..HardFork.high, string] = [
    "cancun",
    "prague",
    "osaka"
  ]

func ofStmt(fork: HardFork, keyName: string, reader: NimNode, value: NimNode): NimNode =
  let branchStmt = quote do:
    `value`[`fork`] = reader.readValue(Opt[BlobSchedule])

  nnkOfBranch.newTree(
    newLit(keyName),
    branchStmt
  )

macro blobScheduleParser(reader, key, value: typed): untyped =
  # Automated blob schedule parser generator
  var caseStmt = nnkCaseStmt.newTree(
    quote do: `key`
  )

  for fork in Cancun..HardFork.high:
    let keyName = BlobScheduleTable[fork]
    caseStmt.add ofStmt(fork, keyName, reader, value)

  caseStmt.add nnkElse.newTree(
    quote do: discard
  )
  result = caseStmt

proc readValue(reader: var JsonReader[JGenesis], value: var array[Cancun..HardFork.high, Opt[BlobSchedule]])
    {.gcsafe, raises: [SerializationError, IOError].} =
  wrapError:
    for key in reader.readObjectFields:
      blobScheduleParser(reader, key, value)

macro fillArrayOfBlockNumberBasedForkOptionals(conf, tmp: typed): untyped =
  result = newStmtList()
  for i, x in forkBlockField:
    let fieldIdent = newIdentNode(x)
    result.add quote do:
      `tmp`[`i`] = BlockNumberBasedForkOptional(
        number  : `conf`.`fieldIdent`,
        name    : `x`)

macro fillArrayOfTimeBasedForkOptionals(conf, tmp: typed): untyped =
  result = newStmtList()
  for i, x in forkTimeField:
    let fieldIdent = newIdentNode(x)
    result.add quote do:
      `tmp`[`i`] = TimeBasedForkOptional(
        time    : `conf`.`fieldIdent`,
        name    : `x`)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func toHardFork*(map: ForkTransitionTable, forkDeterminer: ForkDeterminationInfo): HardFork =
  for fork in countdown(HardFork.high, HardFork.low):
    if isGTETransitionThreshold(map, forkDeterminer, fork):
      return fork

  # should always have a match
  doAssert(false, "unreachable code")

proc validateChainConfig(conf: ChainConfig): bool =
  result = true

  # FIXME: factor this to remove the duplication between the
  # block-based ones and the time-based ones.

  var blockNumberBasedForkOptionals: array[forkBlockField.len, BlockNumberBasedForkOptional]
  fillArrayOfBlockNumberBasedForkOptionals(conf, blockNumberBasedForkOptionals)

  var timeBasedForkOptionals: array[forkTimeField.len, TimeBasedForkOptional]
  fillArrayOfTimeBasedForkOptionals(conf, timeBasedForkOptionals)

  var lastBlockNumberBasedFork = blockNumberBasedForkOptionals[0]
  for i in 1..<blockNumberBasedForkOptionals.len:
    let cur = blockNumberBasedForkOptionals[i]

    if lastBlockNumberBasedFork.number.isSome and cur.number.isSome:
      if lastBlockNumberBasedFork.number.get > cur.number.get:
        error "Unsupported fork ordering",
          lastFork=lastBlockNumberBasedFork.name,
          lastNumber=lastBlockNumberBasedFork.number,
          curFork=cur.name,
          curNumber=cur.number
        return false

    # If it was optional and not set, then ignore it
    if cur.number.isSome:
      lastBlockNumberBasedFork = cur

  # TODO: check to make sure the timestamps are all past the
  # block numbers?

  var lastTimeBasedFork = timeBasedForkOptionals[0]
  for i in 1..<timeBasedForkOptionals.len:
    let cur = timeBasedForkOptionals[i]

    if lastTimeBasedFork.time.isSome and cur.time.isSome:
      if lastTimeBasedFork.time.get > cur.time.get:
        error "Unsupported fork ordering",
          lastFork=lastTimeBasedFork.name,
          lastTime=lastTimeBasedFork.time,
          curFork=cur.name,
          curTime=cur.time
        return false

    # If it was optional and not set, then ignore it
    if cur.time.isSome:
      lastTimeBasedFork = cur

proc configureBlobSchedule(conf: ChainConfig) =
  var prevFork = Cancun
  if conf.blobSchedule[Cancun].isNone:
    conf.blobSchedule[Cancun] = Opt.some(BlobSchedule(target: 3'u64, max: 6'u64, baseFeeUpdateFraction: 3_338_477'u64))
  else:
    if conf.blobSchedule[Cancun].value.baseFeeUpdateFraction == 0:
      conf.blobSchedule[Cancun].value.baseFeeUpdateFraction = 3_338_477'u64

  for fork in Prague..HardFork.high:
    if conf.blobSchedule[fork].isNone:
      conf.blobSchedule[fork] = conf.blobSchedule[prevFork]
    if conf.blobSchedule[fork].value.baseFeeUpdateFraction == 0:
      # Set fallback to Cancun's baseFeeUpdateFraction and prevent division by zero
      warn "baseFeeUpdateFraction not set, fallback to Cancun's", fork=fork
      conf.blobSchedule[fork].value.baseFeeUpdateFraction = 3_338_477'u64
    prevFork = fork

proc parseGenesis*(data: string): Genesis
     {.gcsafe.} =
  try:
    result = JGenesis.decode(data, Genesis, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return nil
  except CatchableError as e:
    error "Error loading genesis data",
      exception = e.name, msg = e.msg
    return nil

proc parseGenesisFile*(fileName: string): Genesis
     {.gcsafe.} =
  try:
    result = JGenesis.loadFile(fileName, Genesis, allowUnknownFields = true)
  except IOError as e:
    error "Genesis I/O error", fileName, msg=e.msg
    return nil
  except JsonReaderError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return nil
  except CatchableError as e:
    error "Error loading genesis file",
      fileName, exception = e.name, msg = e.msg
    return nil

proc validateNetworkParams(params: var NetworkParams, input: string, inputIsFile: bool): bool =
  if params.genesis.isNil:
    # lets try with geth's format
    let genesis = if inputIsFile: parseGenesisFile(input)
                  else: parseGenesis(input)
    if genesis.isNil:
      return false
    params.genesis = genesis

  if params.config.isNil:
    warn "Loaded custom network contains no 'config' data"
    params.config = ChainConfig()

  configureBlobSchedule(params.config)
  validateChainConfig(params.config)

proc loadNetworkParams*(fileName: string, params: var NetworkParams):
    bool =
  try:
    params = JGenesis.loadFile(fileName, NetworkParams, allowUnknownFields = true)
  except IOError as e:
    error "Network params I/O error", fileName, msg=e.msg
    return false
  except JsonReaderError as e:
    error "Invalid network params file format", fileName, msg=e.formatMsg("")
    return false
  except CatchableError as e:
    error "Error loading network params file",
      fileName, exception = e.name, msg = e.msg
    return false

  validateNetworkParams(params, fileName, true)

proc decodeNetworkParams*(jsonString: string, params: var NetworkParams): bool =
  try:
    params = JGenesis.decode(jsonString, NetworkParams, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid network params format", msg=e.formatMsg("")
    return false
  except CatchableError:
    var msg = getCurrentExceptionMsg()
    error "Error decoding network params", msg
    return false

  validateNetworkParams(params, jsonString, false)

proc parseGenesisAlloc*(data: string, ga: var GenesisAlloc): bool
    {.gcsafe, raises: [CatchableError].} =
  try:
    ga = JGenesis.decode(data, GenesisAlloc, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return false

  return true

func defaultBlobSchedule*(): array[Cancun..HardFork.high, Opt[BlobSchedule]] =
  [
    Cancun: Opt.some(BlobSchedule(target: 3'u64, max: 6'u64, baseFeeUpdateFraction: 3_338_477'u64)),
    Prague: Opt.some(BlobSchedule(target: 6'u64, max: 9'u64, baseFeeUpdateFraction: 5_007_716'u64)),
    Osaka : Opt.some(BlobSchedule(target: 9'u64, max: 12'u64, baseFeeUpdateFraction: 5_007_716'u64)),
  ]

func chainConfigForNetwork*(id: NetworkId): ChainConfig =
  # For some public networks, NetworkId and ChainId value are identical
  # but that is not always the case

  result = case id
  of MainNet:
    const
      mainNetTTD = parse("58750000000000000000000",UInt256)
      MAINNET_DEPOSIT_CONTRACT_ADDRESS = address"0x00000000219ab540356cbb839cbe05303d7705fa"
    ChainConfig(
      chainId:             MainNet.ChainId,
      # Genesis (Frontier):                                  # 2015-07-30 15:26:13 UTC
      # Frontier Thawing:  200_000.BlockNumber,              # 2015-09-07 21:33:09 UTC
      homesteadBlock:      Opt.some(1_150_000.BlockNumber),  # 2016-03-14 18:49:53 UTC
      daoForkBlock:        Opt.some(1_920_000.BlockNumber),  # 2016-07-20 13:20:40 UTC
      daoForkSupport:      true,
      eip150Block:         Opt.some(2_463_000.BlockNumber),  # 2016-10-18 13:19:31 UTC
      eip150Hash:          hash32"2086799aeebeae135c246c65021c82b4e15a2c451340993aacfd2751886514f0",
      eip155Block:         Opt.some(2_675_000.BlockNumber),  # Same as EIP-158
      eip158Block:         Opt.some(2_675_000.BlockNumber),  # 2016-11-22 16:15:44 UTC
      byzantiumBlock:      Opt.some(4_370_000.BlockNumber),  # 2017-10-16 05:22:11 UTC
      constantinopleBlock: Opt.some(7_280_000.BlockNumber),  # Skipped on Mainnet
      petersburgBlock:     Opt.some(7_280_000.BlockNumber),  # 2019-02-28 19:52:04 UTC
      istanbulBlock:       Opt.some(9_069_000.BlockNumber),  # 2019-12-08 00:25:09 UTC
      muirGlacierBlock:    Opt.some(9_200_000.BlockNumber),  # 2020-01-02 08:30:49 UTC
      berlinBlock:         Opt.some(12_244_000.BlockNumber), # 2021-04-15 10:07:03 UTC
      londonBlock:         Opt.some(12_965_000.BlockNumber), # 2021-08-05 12:33:42 UTC
      arrowGlacierBlock:   Opt.some(13_773_000.BlockNumber), # 2021-12-09 19:55:23 UTC
      grayGlacierBlock:    Opt.some(15_050_000.BlockNumber), # 2022-06-30 10:54:04 UTC
      posBlock:            Opt.some(15_537_394.BlockNumber), # 2022-09-15 05:42:42 UTC
      terminalTotalDifficulty: Opt.some(mainNetTTD),
      shanghaiTime:        Opt.some(1_681_338_455.EthTime),  # 2023-04-12 10:27:35 UTC
      cancunTime:          Opt.some(1_710_338_135.EthTime),  # 2024-03-13 13:55:35 UTC
      depositContractAddress: Opt.some(MAINNET_DEPOSIT_CONTRACT_ADDRESS),
      blobSchedule:        defaultBlobSchedule(),
    )
  of SepoliaNet:
    # https://github.com/eth-clients/sepolia/blob/f5e3652be045250fd2de1631683b110317592bd3/metadata/genesis.json
    const
      sepoliaTTD = parse("17000000000000000",UInt256)
      SEPOLIANET_DEPOSIT_CONTRACT_ADDRESS = address"0x7f02C3E3c98b133055B8B348B2Ac625669Ed295D"
    ChainConfig(
      chainId:             SepoliaNet.ChainId,
      homesteadBlock:      Opt.some(0.BlockNumber),
      daoForkSupport:      false,
      eip150Block:         Opt.some(0.BlockNumber),
      eip150Hash:          hash32"0000000000000000000000000000000000000000000000000000000000000000",
      eip155Block:         Opt.some(0.BlockNumber),
      eip158Block:         Opt.some(0.BlockNumber),
      byzantiumBlock:      Opt.some(0.BlockNumber),
      constantinopleBlock: Opt.some(0.BlockNumber),
      petersburgBlock:     Opt.some(0.BlockNumber),
      istanbulBlock:       Opt.some(0.BlockNumber),
      muirGlacierBlock:    Opt.some(0.BlockNumber),
      berlinBlock:         Opt.some(0.BlockNumber),
      londonBlock:         Opt.some(0.BlockNumber),
      mergeNetsplitBlock:  Opt.some(1450409.BlockNumber),
      terminalTotalDifficulty: Opt.some(sepoliaTTD),
      shanghaiTime:        Opt.some(1_677_557_088.EthTime),
      cancunTime:          Opt.some(1_706_655_072.EthTime), # 2024-01-30 22:51:12
      pragueTime:          Opt.some(1_741_159_776.EthTime),
      depositContractAddress: Opt.some(SEPOLIANET_DEPOSIT_CONTRACT_ADDRESS),
      blobSchedule:        defaultBlobSchedule(),
    )
  of HoleskyNet:
    #https://github.com/eth-clients/holesky
    const
      HOLESKYNET_DEPOSIT_CONTRACT_ADDRESS = address"0x4242424242424242424242424242424242424242"
    ChainConfig(
      chainId:             HoleskyNet.ChainId,
      homesteadBlock:      Opt.some(0.BlockNumber),
      eip150Block:         Opt.some(0.BlockNumber),
      eip155Block:         Opt.some(0.BlockNumber),
      eip158Block:         Opt.some(0.BlockNumber),
      byzantiumBlock:      Opt.some(0.BlockNumber),
      constantinopleBlock: Opt.some(0.BlockNumber),
      petersburgBlock:     Opt.some(0.BlockNumber),
      istanbulBlock:       Opt.some(0.BlockNumber),
      berlinBlock:         Opt.some(0.BlockNumber),
      londonBlock:         Opt.some(0.BlockNumber),
      mergeNetsplitBlock:  Opt.some(0.BlockNumber),
      terminalTotalDifficulty: Opt.some(0.u256),
      shanghaiTime:        Opt.some(1_696_000_704.EthTime),
      cancunTime:          Opt.some(1_707_305_664.EthTime), # 2024-02-07 11:34:24
      pragueTime:          Opt.some(1_740_434_112.EthTime),
      depositContractAddress: Opt.some(HOLESKYNET_DEPOSIT_CONTRACT_ADDRESS),
      blobSchedule:        defaultBlobSchedule(),
    )
  else:
    ChainConfig()

func genesisBlockForNetwork*(id: NetworkId): Genesis
    {.gcsafe, raises: [ValueError, RlpError].} =
  result = case id
  of MainNet:
    Genesis(
      nonce: uint64(66).to(Bytes8),
      extraData: hexToSeqByte("0x11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa"),
      gasLimit: 5000,
      difficulty: 17179869184.u256,
      alloc: decodePrealloc(mainnetAllocData)
    )
  of SepoliaNet:
    Genesis(
      nonce: uint64(0).to(Bytes8),
      timestamp: EthTime(0x6159af19),
      extraData: hexToSeqByte("0x5365706f6c69612c20417468656e732c204174746963612c2047726565636521"),
      gasLimit: 0x1c9c380,
      difficulty: 0x20000.u256,
      alloc: decodePrealloc(sepoliaAllocData)
    )
  of HoleskyNet:
    Genesis(
      difficulty: 0x01.u256,
      gasLimit: 0x17D7840,
      nonce: uint64(0x1234).to(Bytes8),
      timestamp: EthTime(0x65156994),
      alloc: decodePrealloc(holeskyAllocData)
    )
  else:
    Genesis()

func networkParams*(id: NetworkId): NetworkParams
    {.gcsafe, raises: [ValueError, RlpError].} =
  result.genesis = genesisBlockForNetwork(id)
  result.config  = chainConfigForNetwork(id)

func `==`*(a, b: Genesis): bool =
  if a.isNil and b.isNil: return true
  if a.isNil and not b.isNil: return false
  if not a.isNil and b.isNil: return false
  a[] == b[]

func `==`*(a, b: ChainConfig): bool =
  if a.isNil and b.isNil: return true
  if a.isNil and not b.isNil: return false
  if not a.isNil and b.isNil: return false
  a[] == b[]
