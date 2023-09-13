# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[tables, strutils, options, times, macros],
  eth/[common, rlp, p2p], stint, stew/[byteutils],
  json_serialization, chronicles,
  json_serialization/std/options as jsoptions,
  json_serialization/std/tables as jstable,
  json_serialization/lexer,
  "."/[genesis_alloc, hardforks]

export
  hardforks

type
  Genesis* = ref object
    nonce*      : BlockNonce
    timestamp*  : EthTime
    extraData*  : seq[byte]
    gasLimit*   : GasInt
    difficulty* : DifficultyInt
    mixHash*    : Hash256
    coinbase*   : EthAddress
    alloc*      : GenesisAlloc
    number*     : BlockNumber
    gasUser*    : GasInt
    parentHash* : Hash256
    baseFeePerGas*: Option[UInt256]
    blobGasUsed*  : Option[uint64]    # EIP-4844
    excessBlobGas*: Option[uint64]    # EIP-4844
    parentBeaconBlockRoot*: Option[Hash256]   # EIP-4788

  GenesisAlloc* = Table[EthAddress, GenesisAccount]
  GenesisAccount* = object
    code*   : seq[byte]
    storage*: Table[UInt256, UInt256]
    balance*: UInt256
    nonce*  : AccountNonce

  NetworkParams* = object
    config* : ChainConfig
    genesis*: Genesis

  AddressBalance = object
    address {.rlpCustomSerialization.}: EthAddress
    account {.rlpCustomSerialization.}: GenesisAccount

  GenesisFile* = object
    config      : ChainConfig
    nonce*      : BlockNonce
    timestamp*  : EthTime
    extraData*  : seq[byte]
    gasLimit*   : GasInt
    difficulty* : DifficultyInt
    mixHash*    : Hash256
    coinbase*   : EthAddress
    alloc*      : GenesisAlloc
    number*     : BlockNumber
    gasUser*    : GasInt
    parentHash* : Hash256
    baseFeePerGas*: Option[UInt256]
    blobGasUsed*  : Option[uint64]    # EIP-4844
    excessBlobGas*: Option[uint64]    # EIP-4844
    parentBeaconBlockRoot*: Option[Hash256]   # EIP-4788

const
  CustomNet*  = 0.NetworkId
  # these are public network id
  MainNet*    = 1.NetworkId
  # No longer used: MordenNet = 2
  RopstenNet* = 3.NetworkId
  RinkebyNet* = 4.NetworkId
  GoerliNet*  = 5.NetworkId
  KovanNet*   = 42.NetworkId
  SepoliaNet* = 11155111.NetworkId

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

proc read(rlp: var Rlp, x: var AddressBalance, _: type EthAddress): EthAddress
    {.gcsafe, raises: [RlpError].} =
  let val = rlp.read(UInt256).toBytesBE()
  result[0 .. ^1] = val.toOpenArray(12, val.high)

proc read(rlp: var Rlp, x: var AddressBalance, _: type GenesisAccount): GenesisAccount
    {.gcsafe, raises: [RlpError].} =
  GenesisAccount(balance: rlp.read(UInt256))

func decodePrealloc*(data: seq[byte]): GenesisAlloc
    {.gcsafe, raises: [RlpError].} =
  for tup in rlp.decode(data, seq[AddressBalance]):
    result[tup.address] = tup.account

# borrowed from `lexer.hexCharValue()` :)
proc fromHex(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc readValue(reader: var JsonReader, value: var UInt256)
    {.gcsafe, raises: [SerializationError, IOError].} =
  ## Mixin for `Json.loadFile()`. Note that this driver applies the same
  ## to `BlockNumber` fields as well as generic `UInt265` fields like the
  ## account `balance`.
  var (accu, ok) = (0.u256, true)
  if reader.lexer.lazyTok == tkNumeric:
    try:
      reader.lexer.customIntValueIt:
        accu = accu * 10 + it.u256
      ok = reader.lexer.lazyTok == tkExInt # non-negative wanted
    except CatchableError:
      ok = false
  elif reader.lexer.lazyTok == tkQuoted:
    try:
      var (sLen, base) = (0, 10)
      reader.lexer.customTextValueIt:
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
  reader.lexer.next()

proc readValue(reader: var JsonReader, value: var ChainId)
    {.gcsafe, raises: [SerializationError, IOError].} =
  value = reader.readValue(int).ChainId

proc readValue(reader: var JsonReader, value: var Hash256)
    {.gcsafe, raises: [SerializationError, IOError].} =
  value = Hash256.fromHex(reader.readValue(string))

proc readValue(reader: var JsonReader, value: var BlockNonce)
    {.gcsafe, raises: [SerializationError, IOError].} =
  try:
    value = fromHex[uint64](reader.readValue(string)).toBlockNonce
  except ValueError as ex:
    reader.raiseUnexpectedValue(ex.msg)

# genesis timestamp is in hex
proc readValue(reader: var JsonReader, value: var EthTime)
    {.gcsafe, raises: [SerializationError, IOError].} =
  try:
    value = fromHex[int64](reader.readValue(string)).fromUnix
  except ValueError as ex:
    reader.raiseUnexpectedValue(ex.msg)

# but shanghaiTime and cancunTime in config is in int literal
proc readValue(reader: var JsonReader, value: var Option[EthTime])
    {.gcsafe, raises: [SerializationError, IOError].} =
  let tok = reader.lexer.lazyTok
  if tok == tkNull:
    reset value
    reader.lexer.next()
  else:
    # both readValue(GasInt/AccountNonce) will be called if
    # we use readValue(int64/uint64)
    let tok {.used.} = reader.lexer.tok # resove lazy token
    let val = reader.lexer.absIntVal.int64
    value = some val.fromUnix
    reader.lexer.next()

proc readValue(reader: var JsonReader, value: var seq[byte])
    {.gcsafe, raises: [SerializationError, IOError].} =
  try:
    value = hexToSeqByte(reader.readValue(string))
  except ValueError as ex:
    reader.raiseUnexpectedValue(ex.msg)

proc readValue(reader: var JsonReader, value: var GasInt)
    {.gcsafe, raises: [SerializationError, IOError].} =
  try:
    value = fromHex[GasInt](reader.readValue(string))
  except ValueError as ex:
    reader.raiseUnexpectedValue(ex.msg)

proc readValue(reader: var JsonReader, value: var EthAddress)
    {.gcsafe, raises: [SerializationError, IOError].} =
  try:
    value = parseAddress(reader.readValue(string))
  except ValueError as ex:
    reader.raiseUnexpectedValue(ex.msg)

proc readValue(reader: var JsonReader, value: var AccountNonce)
    {.gcsafe, raises: [SerializationError, IOError].} =
  try:
    value = fromHex[uint64](reader.readValue(string))
  except ValueError as ex:
    reader.raiseUnexpectedValue(ex.msg)

template to(a: string, b: type EthAddress): EthAddress =
  # json_serialization decode table stuff
  parseAddress(a)

template to(a: string, b: type UInt256): UInt256 =
  # json_serialization decode table stuff
  UInt256.fromHex(a)

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

proc toHardFork*(map: ForkTransitionTable, forkDeterminer: ForkDeterminationInfo): HardFork =
  for fork in countdown(HardFork.high, HardFork.low):
    if isGTETransitionThreshold(map, forkDeterminer, fork):
      return fork

  # should always have a match
  doAssert(false, "unreachable code")

func forkDeterminationInfoForHeader*(header: BlockHeader): ForkDeterminationInfo =
  # FIXME-Adam-mightAlsoNeedTTD?
  forkDeterminationInfo(header.blockNumber, header.timestamp)

proc validateChainConfig*(conf: ChainConfig): bool =
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

  if conf.clique.period.isSome or
     conf.clique.epoch.isSome:
    conf.consensusType = ConsensusType.POA

proc validateNetworkParams*(params: var NetworkParams): bool =
  if params.genesis.isNil:
    warn "Loaded custom network contains no 'genesis' data"

  if params.config.isNil:
    warn "Loaded custom network contains no 'config' data"
    params.config = ChainConfig()

  validateChainConfig(params.config)

proc loadNetworkParams*(fileName: string, params: var NetworkParams):
    bool =
  try:
    params = Json.loadFile(fileName, NetworkParams, allowUnknownFields = true)
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

  validateNetworkParams(params)

proc decodeNetworkParams*(jsonString: string, params: var NetworkParams): bool =
  try:
    params = Json.decode(jsonString, NetworkParams, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid network params format", msg=e.formatMsg("")
    return false
  except CatchableError:
    var msg = getCurrentExceptionMsg()
    error "Error decoding network params", msg
    return false

  validateNetworkParams(params)

proc parseGenesisAlloc*(data: string, ga: var GenesisAlloc): bool
    {.gcsafe, raises: [CatchableError].} =
  try:
    ga = Json.decode(data, GenesisAlloc, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return false

  return true

proc parseGenesis*(data: string): Genesis
     {.gcsafe, raises: [CatchableError].} =
  try:
    result = Json.decode(data, Genesis, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return nil

proc chainConfigForNetwork*(id: NetworkId): ChainConfig =
  # For some public networks, NetworkId and ChainId value are identical
  # but that is not always the case

  result = case id
  of MainNet:
    const mainNetTTD = parse("58750000000000000000000",UInt256)
    ChainConfig(
      consensusType:       ConsensusType.POW,
      chainId:             MainNet.ChainId,
      # Genesis (Frontier):                                # 2015-07-30 15:26:13 UTC
      # Frontier Thawing:  200_000.toBlockNumber,          # 2015-09-07 21:33:09 UTC
      homesteadBlock:      some(1_150_000.toBlockNumber),  # 2016-03-14 18:49:53 UTC
      daoForkBlock:        some(1_920_000.toBlockNumber),  # 2016-07-20 13:20:40 UTC
      daoForkSupport:      true,
      eip150Block:         some(2_463_000.toBlockNumber),  # 2016-10-18 13:19:31 UTC
      eip150Hash:          toDigest("2086799aeebeae135c246c65021c82b4e15a2c451340993aacfd2751886514f0"),
      eip155Block:         some(2_675_000.toBlockNumber),  # Same as EIP-158
      eip158Block:         some(2_675_000.toBlockNumber),  # 2016-11-22 16:15:44 UTC
      byzantiumBlock:      some(4_370_000.toBlockNumber),  # 2017-10-16 05:22:11 UTC
      constantinopleBlock: some(7_280_000.toBlockNumber),  # Skipped on Mainnet
      petersburgBlock:     some(7_280_000.toBlockNumber),  # 2019-02-28 19:52:04 UTC
      istanbulBlock:       some(9_069_000.toBlockNumber),  # 2019-12-08 00:25:09 UTC
      muirGlacierBlock:    some(9_200_000.toBlockNumber),  # 2020-01-02 08:30:49 UTC
      berlinBlock:         some(12_244_000.toBlockNumber), # 2021-04-15 10:07:03 UTC
      londonBlock:         some(12_965_000.toBlockNumber), # 2021-08-05 12:33:42 UTC
      arrowGlacierBlock:   some(13_773_000.toBlockNumber), # 2021-12-09 19:55:23 UTC
      grayGlacierBlock:    some(15_050_000.toBlockNumber), # 2022-06-30 10:54:04 UTC
      terminalTotalDifficulty: some(mainNetTTD),
      shanghaiTime:        some(1_681_338_455.fromUnix)
    )
  of RopstenNet:
    ChainConfig(
      consensusType:       ConsensusType.POW,
      chainId:             RopstenNet.ChainId,
      # Genesis:                                           # 2016-11-20 11:48:50 UTC
      homesteadBlock:      some(0.toBlockNumber),          # Included in genesis
      daoForkSupport:      false,
      eip150Block:         some(0.toBlockNumber),          # Included in genesis
      eip150Hash:          toDigest("41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d"),
      eip155Block:         some(10.toBlockNumber),         # Same as EIP-158
      eip158Block:         some(10.toBlockNumber),         # 2016-11-20 11:50:44 UTC
      byzantiumBlock:      some(1_700_000.toBlockNumber),  # 2017-09-19 01:08:28 UTC
      constantinopleBlock: some(4_230_000.toBlockNumber),  # 2018-10-13 17:19:06 UTC
      petersburgBlock:     some(4_939_394.toBlockNumber),  # 2019-02-02 07:39:08 UTC
      istanbulBlock:       some(6_485_846.toBlockNumber),  # 2019-09-30 03:38:06 UTC
      muirGlacierBlock:    some(7_117_117.toBlockNumber),  # 2020-01-13 06:37:37 UTC
      berlinBlock:         some(9_812_189.toBlockNumber),  # 2021-03-10 13:32:08 UTC
      londonBlock:         some(10_499_401.toBlockNumber), # 2021-06-24 02:03:37 UTC
    )
  of RinkebyNet:
    ChainConfig(
      clique:              CliqueOptions(period: some(15), epoch: some(30000)),
      consensusType:       ConsensusType.POA,
      chainId:             RinkebyNet.ChainId,
      # Genesis:                                           # 2017-04-12 15:20:50 UTC
      homesteadBlock:      some(1.toBlockNumber),          # 2017-04-12 15:20:58 UTC
      daoForkSupport:      false,
      eip150Block:         some(2.toBlockNumber),          # 2017-04-12 15:21:14 UTC
      eip150Hash:          toDigest("9b095b36c15eaf13044373aef8ee0bd3a382a5abb92e402afa44b8249c3a90e9"),
      eip155Block:         some(3.toBlockNumber),          # Same as EIP-158
      eip158Block:         some(3.toBlockNumber),          # 2017-04-12 15:21:29 UTC
      byzantiumBlock:      some(1_035_301.toBlockNumber),  # 2017-10-09 12:08:23 UTC
      constantinopleBlock: some(3_660_663.toBlockNumber),  # 2019-01-09 13:00:55 UTC
      petersburgBlock:     some(4_321_234.toBlockNumber),  # 2019-05-04 05:32:45 UTC
      istanbulBlock:       some(5_435_345.toBlockNumber),  # 2019-11-13 18:21:53 UTC
      muirGlacierBlock:    some(8_290_928.toBlockNumber),  # Skipped on Rinkeby
      berlinBlock:         some(8_290_928.toBlockNumber),  # 2021-03-24 14:48:36 UTC
      londonBlock:         some(8_897_988.toBlockNumber),  # 2021-07-08 01:27:32 UTC
    )
  of GoerliNet:
    ChainConfig(
      clique:              CliqueOptions(period: some(15), epoch: some(30000)),
      consensusType:       ConsensusType.POA,
      chainId:             GoerliNet.ChainId,
      # Genesis:                                           # 2015-07-30 15:26:13 UTC
      homesteadBlock:      some(0.toBlockNumber),          # Included in genesis
      daoForkSupport:      false,
      eip150Block:         some(0.toBlockNumber),          # Included in genesis
      eip150Hash:          toDigest("0000000000000000000000000000000000000000000000000000000000000000"),
      eip155Block:         some(0.toBlockNumber),          # Included in genesis
      eip158Block:         some(0.toBlockNumber),          # Included in genesis
      byzantiumBlock:      some(0.toBlockNumber),          # Included in genesis
      constantinopleBlock: some(0.toBlockNumber),          # Included in genesis
      petersburgBlock:     some(0.toBlockNumber),          # Included in genesis
      istanbulBlock:       some(1_561_651.toBlockNumber),  # 2019-10-30 13:53:05 UTC
      muirGlacierBlock:    some(4_460_644.toBlockNumber),  # Skipped in Goerli
      berlinBlock:         some(4_460_644.toBlockNumber),  # 2021-03-18 05:29:51 UTC
      londonBlock:         some(5_062_605.toBlockNumber),  # 2021-07-01 03:19:39 UTC
      terminalTotalDifficulty: some(10790000.u256),
      shanghaiTime:        some(1_678_832_736.fromUnix)
    )
  of SepoliaNet:
    ChainConfig(
      consensusType:       ConsensusType.POW,
      chainId:             SepoliaNet.ChainId,
      homesteadBlock:      some(0.toBlockNumber),
      daoForkSupport:      false,
      eip150Block:         some(0.toBlockNumber),
      eip150Hash:          toDigest("0000000000000000000000000000000000000000000000000000000000000000"),
      eip155Block:         some(0.toBlockNumber),
      eip158Block:         some(0.toBlockNumber),
      byzantiumBlock:      some(0.toBlockNumber),
      constantinopleBlock: some(0.toBlockNumber),
      petersburgBlock:     some(0.toBlockNumber),
      istanbulBlock:       some(0.toBlockNumber),
      muirGlacierBlock:    some(0.toBlockNumber),
      berlinBlock:         some(0.toBlockNumber),
      londonBlock:         some(0.toBlockNumber),
      shanghaiTime:        some(1_677_557_088.fromUnix)
    )
  else:
    ChainConfig()

proc genesisBlockForNetwork*(id: NetworkId): Genesis
    {.gcsafe, raises: [ValueError, RlpError].} =
  result = case id
  of MainNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa"),
      gasLimit: 5000,
      difficulty: 17179869184.u256,
      alloc: decodePrealloc(mainnetAllocData)
    )
  of RopstenNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x3535353535353535353535353535353535353535353535353535353535353535"),
      gasLimit: 16777216,
      difficulty: 1048576.u256,
      alloc: decodePrealloc(testnetAllocData)
    )
  of RinkebyNet:
    Genesis(
      nonce: 0.toBlockNonce,
      timestamp: initTime(0x58ee40ba, 0),
      extraData: hexToSeqByte("0x52657370656374206d7920617574686f7269746168207e452e436172746d616e42eb768f2244c8811c63729a21a3569731535f067ffc57839b00206d1ad20c69a1981b489f772031b279182d99e65703f0076e4812653aab85fca0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
      gasLimit: 4700000,
      difficulty: 1.u256,
      alloc: decodePrealloc(rinkebyAllocData)
    )
  of GoerliNet:
    Genesis(
      nonce: 0.toBlockNonce,
      timestamp: initTime(0x5c51a607, 0),
      extraData: hexToSeqByte("0x22466c6578692069732061207468696e6722202d204166726900000000000000e0a2bd4258d2768837baa26a28fe71dc079f84c70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
      gasLimit: 0xa00000,
      difficulty: 1.u256,
      alloc: decodePrealloc(goerliAllocData)
    )
  of SepoliaNet:
    Genesis(
      nonce: 0.toBlockNonce,
      timestamp: initTime(0x6159af19, 0),
      extraData: hexToSeqByte("0x5365706f6c69612c20417468656e732c204174746963612c2047726565636521"),
      gasLimit: 0x1c9c380,
      difficulty: 0x20000.u256,
      alloc: decodePrealloc(sepoliaAllocData)
    )
  else:
    Genesis()

proc networkParams*(id: NetworkId): NetworkParams
    {.gcsafe, raises: [ValueError, RlpError].} =
  result.genesis = genesisBlockForNetwork(id)
  result.config  = chainConfigForNetwork(id)

proc `==`*(a, b: ChainId): bool =
  a.uint64 == b.uint64

proc `==`*(a, b: Genesis): bool =
  if a.isNil and b.isNil: return true
  if a.isNil and not b.isNil: return false
  if not a.isNil and b.isNil: return false
  a[] == b[]

proc `==`*(a, b: ChainConfig): bool =
  if a.isNil and b.isNil: return true
  if a.isNil and not b.isNil: return false
  if not a.isNil and b.isNil: return false
  a[] == b[]
