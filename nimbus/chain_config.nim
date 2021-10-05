# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, strutils, options, times],
  eth/[common, rlp, p2p], stint, stew/[byteutils],
  nimcrypto/hash,
  json_serialization, chronicles,
  json_serialization/std/options as jsoptions,
  json_serialization/std/tables as jstable,
  json_serialization/lexer,
  "."/[forks, genesis_alloc]

type
  CliqueOptions = object
    epoch : Option[int]
    period: Option[int]

  ChainOptions = object
    chainId            : ChainId
    homesteadBlock     : Option[BlockNumber]
    daoForkBlock       : Option[BlockNumber]
    daoForkSupport     : bool
    eip150Block        : Option[BlockNumber]
    eip150Hash         : Hash256
    eip155Block        : Option[BlockNumber]
    eip158Block        : Option[BlockNumber]
    byzantiumBlock     : Option[BlockNumber]
    constantinopleBlock: Option[BlockNumber]
    petersburgBlock    : Option[BlockNumber]
    istanbulBlock      : Option[BlockNumber]
    muirGlacierBlock   : Option[BlockNumber]
    berlinBlock        : Option[BlockNumber]
    londonBlock        : Option[BlockNumber]
    clique             : CliqueOptions
    terminalTotalDifficulty*: Option[UInt256]

  ChainConfig* = object
    chainId*            : ChainId
    homesteadBlock*     : BlockNumber
    daoForkBlock*       : BlockNumber
    daoForkSupport*     : bool

    # EIP150 implements the Gas price changes (https://github.com/ethereum/EIPs/issues/150)
    eip150Block*        : BlockNumber
    eip150Hash*         : Hash256

    eip155Block*        : BlockNumber
    eip158Block*        : BlockNumber

    byzantiumBlock*     : BlockNumber
    constantinopleBlock*: BlockNumber
    petersburgBlock*    : BlockNumber
    istanbulBlock*      : BlockNumber
    muirGlacierBlock*   : BlockNumber
    berlinBlock*        : BlockNumber
    londonBlock*        : BlockNumber

    poaEngine*          : bool
    cliquePeriod*       : int
    cliqueEpoch*        : int

    terminalTotalDifficulty*: Option[UInt256]

  Genesis* = object
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

  CustomChain = object
    config : ChainOptions
    genesis: Genesis

  GenesisFile* = object
    config      : ChainOptions
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

const
  CustomNet*  = 0.NetworkId
  # these are public network id
  MainNet*    = 1.NetworkId
  # No longer used: MordenNet = 2
  RopstenNet* = 3.NetworkId
  RinkebyNet* = 4.NetworkId
  GoerliNet*  = 5.NetworkId
  KovanNet*   = 42.NetworkId

proc read(rlp: var Rlp, x: var AddressBalance, _: type EthAddress): EthAddress {.inline.} =
  let val = rlp.read(UInt256).toByteArrayBE()
  result[0 .. ^1] = val.toOpenArray(12, val.high)

proc read(rlp: var Rlp, x: var AddressBalance, _: type GenesisAccount): GenesisAccount {.inline.} =
  GenesisAccount(balance: rlp.read(UInt256))

func decodePrealloc*(data: seq[byte]): GenesisAlloc =
  for tup in rlp.decode(data, seq[AddressBalance]):
    result[tup.address] = tup.account

proc readValue(reader: var JsonReader, value: var BlockNumber) =
  let tok = reader.lexer.tok
  if tok == tkInt:
    value = toBlockNumber(reader.lexer.absintVal)
    reader.lexer.next()
  elif tok == tkString:
    value = UInt256.fromHex(reader.lexer.strVal)
    reader.lexer.next()
  else:
    reader.raiseUnexpectedValue("expect int or hex string")

proc readValue(reader: var JsonReader, value: var ChainId) =
  value = reader.readValue(int).ChainId

proc readValue(reader: var JsonReader, value: var Hash256) =
  value = Hash256.fromHex(reader.readValue(string))

proc readValue(reader: var JsonReader, value: var BlockNonce) =
  value = fromHex[uint64](reader.readValue(string)).toBlockNonce

proc readValue(reader: var JsonReader, value: var EthTime) =
  value = fromHex[int64](reader.readValue(string)).fromUnix

proc readValue(reader: var JsonReader, value: var seq[byte]) =
  value = hexToSeqByte(reader.readValue(string))

proc readValue(reader: var JsonReader, value: var GasInt) =
  value = fromHex[GasInt](reader.readValue(string))

proc readValue(reader: var JsonReader, value: var EthAddress) =
  value = parseAddress(reader.readValue(string))

proc readValue(reader: var JsonReader, value: var AccountNonce) =
  value = fromHex[uint64](reader.readValue(string))

template to(a: string, b: type EthAddress): EthAddress =
  # json_serialization decode table stuff
  parseAddress(a)

template to(a: string, b: type UInt256): UInt256 =
  # json_serialization decode table stuff
  UInt256.fromHex(a)

proc loadNetworkParams*(fileName: string, cg: var NetworkParams): bool =
  var cc: CustomChain
  try:
    cc = Json.loadFile(fileName, CustomChain, allowUnknownFields = true)
  except IOError as e:
    error "Network params I/O error", fileName, msg=e.msg
    return false
  except JsonReaderError as e:
    error "Invalid network params file format", fileName, msg=e.formatMsg("")
    return false
  except:
    var msg = getCurrentExceptionMsg()
    error "Error loading network params file", fileName, msg
    return false

  cg.genesis               = cc.genesis
  cg.config.chainId        = cc.config.chainId
  cg.config.daoForkSupport = cc.config.daoForkSupport
  cg.config.eip150Hash     = cc.config.eip150Hash

  cg.config.poaEngine      = false

  if cc.config.clique.period.isSome or
    cc.config.clique.epoch.isSome:
    cg.config.poaEngine = true

  if cc.config.clique.period.isSome:
    cg.config.cliquePeriod = cc.config.clique.period.get()

  if cc.config.clique.epoch.isSome:
    cg.config.cliqueEpoch = cc.config.clique.epoch.get()

  cg.config.terminalTotalDifficulty = cc.config.terminalTotalDifficulty

  template validateFork(forkName: untyped, nextBlock: BlockNumber) =
    let fork = astToStr(forkName)
    if cc.config.forkName.isSome:
      cg.config.forkName = cc.config.forkName.get()
    else:
      cg.config.forkName = nextBlock
    if cg.config.forkName > nextBlock:
      error "Forks can't be assigned out of order", fork=fork
      return false

  validateFork(londonBlock,         high(BlockNumber).toBlockNumber)
  validateFork(berlinBlock,         cg.config.londonBlock)
  validateFork(muirGlacierBlock,    cg.config.berlinBlock)
  validateFork(istanbulBlock,       cg.config.muirGlacierBlock)
  validateFork(petersburgBlock,     cg.config.istanbulBlock)
  validateFork(constantinopleBlock, cg.config.petersburgBlock)
  validateFork(byzantiumBlock,      cg.config.constantinopleBlock)
  validateFork(eip158Block,         cg.config.byzantiumBlock)
  validateFork(eip155Block,         cg.config.eip158Block)
  validateFork(eip150Block,         cg.config.eip155Block)
  validateFork(daoForkBlock,        cg.config.eip150Block)
  validateFork(homesteadBlock,      cg.config.daoForkBlock)

  return true

proc parseGenesisAlloc*(data: string, ga: var GenesisAlloc): bool =
  try:
    ga = Json.decode(data, GenesisAlloc, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return false

  return true

proc toFork*(c: ChainConfig, number: BlockNumber): Fork =
  if number >= c.londonBlock: FkLondon
  elif number >= c.berlinBlock: FkBerlin
  elif number >= c.istanbulBlock: FkIstanbul
  elif number >= c.petersburgBlock: FkPetersburg
  elif number >= c.constantinopleBlock: FkConstantinople
  elif number >= c.byzantiumBlock: FkByzantium
  elif number >= c.eip158Block: FkSpurious
  elif number >= c.eip150Block: FkTangerine
  elif number >= c.homesteadBlock: FkHomestead
  else: FkFrontier

proc chainConfigForNetwork(id: NetworkId): ChainConfig =
  # For some public networks, NetworkId and ChainId value are identical
  # but that is not always the case

  result = case id
  of MainNet:
    ChainConfig(
      poaEngine:      false,
      chainId:        MainNet.ChainId,
      homesteadBlock: 1_150_000.toBlockNumber, # 14/03/2016 20:49:53
      daoForkBlock:   1_920_000.toBlockNumber,
      daoForkSupport: true,
      eip150Block:    2_463_000.toBlockNumber, # 18/10/2016 17:19:31
      eip150Hash:     toDigest("2086799aeebeae135c246c65021c82b4e15a2c451340993aacfd2751886514f0"),
      eip155Block:    2_675_000.toBlockNumber, # 22/11/2016 18:15:44
      eip158Block:    2_675_000.toBlockNumber,
      byzantiumBlock: 4_370_000.toBlockNumber, # 16/10/2017 09:22:11
      constantinopleBlock: 7_280_000.toBlockNumber, # Never Occured in MainNet
      petersburgBlock:7_280_000.toBlockNumber, # 28/02/2019 07:52:04
      istanbulBlock:  9_069_000.toBlockNumber, # 08/12/2019 12:25:09
      muirGlacierBlock: 9_200_000.toBlockNumber, # 02/01/2020 08:30:49
      berlinBlock:    12_244_000.toBlockNumber, # 15/04/2021 10:07:03
      londonBlock:    12_965_000.toBlockNumber, # 05/08/2021 12:33:42
    )
  of RopstenNet:
    ChainConfig(
      poaEngine:      false,
      chainId:        RopstenNet.ChainId,
      homesteadBlock: 0.toBlockNumber,
      daoForkSupport: false,
      eip150Block:    0.toBlockNumber,
      eip150Hash:     toDigest("41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d"),
      eip155Block:    10.toBlockNumber,
      eip158Block:    10.toBlockNumber,
      byzantiumBlock: 1_700_000.toBlockNumber,
      constantinopleBlock: 4_230_000.toBlockNumber,
      petersburgBlock:4_939_394.toBlockNumber,
      istanbulBlock:  6_485_846.toBlockNumber,
      muirGlacierBlock: 7_117_117.toBlockNumber,
      berlinBlock:      9_812_189.toBlockNumber,
      londonBlock:    10_499_401.toBlockNumber # June 24, 2021
    )
  of RinkebyNet:
    ChainConfig(
      poaEngine:      true,
      chainId:        RinkebyNet.ChainId,
      homesteadBlock: 1.toBlockNumber,
      daoForkSupport: false,
      eip150Block:    2.toBlockNumber,
      eip150Hash:     toDigest("9b095b36c15eaf13044373aef8ee0bd3a382a5abb92e402afa44b8249c3a90e9"),
      eip155Block:    3.toBlockNumber,
      eip158Block:    3.toBlockNumber,
      byzantiumBlock: 1_035_301.toBlockNumber,
      constantinopleBlock: 3_660_663.toBlockNumber,
      petersburgBlock:4_321_234.toBlockNumber,
      istanbulBlock:  5_435_345.toBlockNumber,
      muirGlacierBlock: 8_290_928.toBlockNumber, # never occured in rinkeby network
      berlinBlock:      8_290_928.toBlockNumber,
      londonBlock:    8_897_988.toBlockNumber # July 7, 2021
    )
  of GoerliNet:
    ChainConfig(
      poaEngine:      true,
      chainId:        GoerliNet.ChainId,
      homesteadBlock: 0.toBlockNumber,
      daoForkSupport: false,
      eip150Block:    0.toBlockNumber,
      eip150Hash:     toDigest("0000000000000000000000000000000000000000000000000000000000000000"),
      eip155Block:    0.toBlockNumber,
      eip158Block:    0.toBlockNumber,
      byzantiumBlock: 0.toBlockNumber,
      constantinopleBlock: 0.toBlockNumber,
      petersburgBlock: 0.toBlockNumber,
      istanbulBlock:  1_561_651.toBlockNumber,
      muirGlacierBlock: 4_460_644.toBlockNumber, # never occured in goerli network
      berlinBlock:    4_460_644.toBlockNumber,
      londonBlock:    5_062_605.toBlockNumber # June 30, 2021
    )
  else:
    ChainConfig()

proc genesisBlockForNetwork(id: NetworkId): Genesis =
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
  else:
    Genesis()

proc networkParams*(id: NetworkId): NetworkParams =
  result.genesis = genesisBlockForNetwork(id)
  result.config  = chainConfigForNetwork(id)
