# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, strutils,sequtils, options, times],
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
    arrowGlacierBlock  : Option[BlockNumber]
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
    arrowGlacierBlock*  : BlockNumber

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

proc readValue(reader: var JsonReader, value: var UInt256) =
  ## Mixin for `Json.loadFile()`. Note that this driver applies the same
  ## to `BlockNumber` fields as well as generic `UInt265` fields like the
  ## account `balance`.
  let tok = reader.lexer.tok
  if tok == tkInt:
    value = reader.lexer.absintVal.u256
    reader.lexer.next()
  elif tok == tkString:
    # Make sure that "0x11" decodes to 17, "b" and "11" decode to 11.
    if reader.lexer.strVal.filterIt(it.isDigit.not).len == 0:
      try:    value = reader.lexer.strVal.parse(UInt256, radix = 10)
      except: reader.raiseUnexpectedValue("int string overflow")
    else:
      # note that radix is static, so 16 (or 10) cannot be a variable
      try:    value = reader.lexer.strVal.parse(UInt256, radix = 16)
      except: reader.raiseUnexpectedValue("hex string parse error")
    reader.lexer.next()
  else:
    reader.raiseUnexpectedValue("expect int or hex/int string")

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

proc loadNetworkParams*(cc: CustomChain, cg: var NetworkParams):
    bool {.raises: [Defect].} =

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

  validateFork(arrowGlacierBlock,   high(BlockNumber))
  validateFork(londonBlock,         cg.config.arrowGlacierBlock)
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

proc loadNetworkParams*(fileName: string, cg: var NetworkParams):
    bool {.raises: [Defect].} =
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

  loadNetworkParams(cc, cg)

proc decodeNetworkParams*(jsonString: string, cg: var NetworkParams):
    bool {.raises: [Defect].} =

  var cc: CustomChain
  try:
    cc = Json.decode(jsonString, CustomChain, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid network params format", msg=e.formatMsg("")
    return false
  except:
    var msg = getCurrentExceptionMsg()
    error "Error decoding network params", msg
    return false

  loadNetworkParams(cc, cg)

proc parseGenesisAlloc*(data: string, ga: var GenesisAlloc): bool =
  try:
    ga = Json.decode(data, GenesisAlloc, allowUnknownFields = true)
  except JsonReaderError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return false

  return true

proc toFork*(c: ChainConfig, number: BlockNumber): Fork =
  ## Map to EVM fork, which doesn't include the DAO or Glacier forks.
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
      poaEngine:           false,
      chainId:             MainNet.ChainId,
      # Genesis (Frontier):                          # 2015-07-30 15:26:13 UTC
      # Frontier Thawing:  200_000.toBlockNumber,    # 2015-09-07 21:33:09 UTC
      homesteadBlock:      1_150_000.toBlockNumber,  # 2016-03-14 18:49:53 UTC
      daoForkBlock:        1_920_000.toBlockNumber,  # 2016-07-20 13:20:40 UTC
      daoForkSupport:      true,
      eip150Block:         2_463_000.toBlockNumber,  # 2016-10-18 13:19:31 UTC
      eip150Hash:          toDigest("2086799aeebeae135c246c65021c82b4e15a2c451340993aacfd2751886514f0"),
      eip155Block:         2_675_000.toBlockNumber,  # Same as EIP-158
      eip158Block:         2_675_000.toBlockNumber,  # 2016-11-22 16:15:44 UTC
      byzantiumBlock:      4_370_000.toBlockNumber,  # 2017-10-16 05:22:11 UTC
      constantinopleBlock: 7_280_000.toBlockNumber,  # Skipped on Mainnet
      petersburgBlock:     7_280_000.toBlockNumber,  # 2019-02-28 19:52:04 UTC
      istanbulBlock:       9_069_000.toBlockNumber,  # 2019-12-08 00:25:09 UTC
      muirGlacierBlock:    9_200_000.toBlockNumber,  # 2020-01-02 08:30:49 UTC
      berlinBlock:         12_244_000.toBlockNumber, # 2021-04-15 10:07:03 UTC
      londonBlock:         12_965_000.toBlockNumber, # 2021-08-05 12:33:42 UTC
      arrowGlacierBlock:   13_773_000.toBlockNumber, # 2021-12-09 19:55:23 UTC
    )
  of RopstenNet:
    ChainConfig(
      poaEngine:           false,
      chainId:             RopstenNet.ChainId,
      # Genesis:                                     # 2016-11-20 11:48:50 UTC
      homesteadBlock:      0.toBlockNumber,          # Included in genesis
      daoForkSupport:      false,
      eip150Block:         0.toBlockNumber,          # Included in genesis
      eip150Hash:          toDigest("41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d"),
      eip155Block:         10.toBlockNumber,         # Same as EIP-158
      eip158Block:         10.toBlockNumber,         # 2016-11-20 11:50:44 UTC
      byzantiumBlock:      1_700_000.toBlockNumber,  # 2017-09-19 01:08:28 UTC
      constantinopleBlock: 4_230_000.toBlockNumber,  # 2018-10-13 17:19:06 UTC
      petersburgBlock:     4_939_394.toBlockNumber,  # 2019-02-02 07:39:08 UTC
      istanbulBlock:       6_485_846.toBlockNumber,  # 2019-09-30 03:38:06 UTC
      muirGlacierBlock:    7_117_117.toBlockNumber,  # 2020-01-13 06:37:37 UTC
      berlinBlock:         9_812_189.toBlockNumber,  # 2021-03-10 13:32:08 UTC
      londonBlock:         10_499_401.toBlockNumber, # 2021-06-24 02:03:37 UTC
      arrowGlacierBlock:   high(BlockNumber),        # No current plan
    )
  of RinkebyNet:
    ChainConfig(
      poaEngine:           true,
      chainId:             RinkebyNet.ChainId,
      # Genesis:                                     # 2017-04-12 15:20:50 UTC
      homesteadBlock:      1.toBlockNumber,          # 2017-04-12 15:20:58 UTC
      daoForkSupport:      false,
      eip150Block:         2.toBlockNumber,          # 2017-04-12 15:21:14 UTC
      eip150Hash:          toDigest("9b095b36c15eaf13044373aef8ee0bd3a382a5abb92e402afa44b8249c3a90e9"),
      eip155Block:         3.toBlockNumber,          # Same as EIP-158
      eip158Block:         3.toBlockNumber,          # 2017-04-12 15:21:29 UTC
      byzantiumBlock:      1_035_301.toBlockNumber,  # 2017-10-09 12:08:23 UTC
      constantinopleBlock: 3_660_663.toBlockNumber,  # 2019-01-09 13:00:55 UTC
      petersburgBlock:     4_321_234.toBlockNumber,  # 2019-05-04 05:32:45 UTC
      istanbulBlock:       5_435_345.toBlockNumber,  # 2019-11-13 18:21:53 UTC
      muirGlacierBlock:    8_290_928.toBlockNumber,  # Skipped on Rinkeby
      berlinBlock:         8_290_928.toBlockNumber,  # 2021-03-24 14:48:36 UTC
      londonBlock:         8_897_988.toBlockNumber,  # 2021-07-08 01:27:32 UTC
      arrowGlacierBlock:   high(BlockNumber),        # No current plan
    )
  of GoerliNet:
    ChainConfig(
      poaEngine:           true,
      chainId:             GoerliNet.ChainId,
      # Genesis:                                     # 2015-07-30 15:26:13 UTC
      homesteadBlock:      0.toBlockNumber,          # Included in genesis
      daoForkSupport:      false,
      eip150Block:         0.toBlockNumber,          # Included in genesis
      eip150Hash:          toDigest("0000000000000000000000000000000000000000000000000000000000000000"),
      eip155Block:         0.toBlockNumber,          # Included in genesis
      eip158Block:         0.toBlockNumber,          # Included in genesis
      byzantiumBlock:      0.toBlockNumber,          # Included in genesis
      constantinopleBlock: 0.toBlockNumber,          # Included in genesis
      petersburgBlock:     0.toBlockNumber,          # Included in genesis
      istanbulBlock:       1_561_651.toBlockNumber,  # 2019-10-30 13:53:05 UTC
      muirGlacierBlock:    4_460_644.toBlockNumber,  # Skipped in Goerli
      berlinBlock:         4_460_644.toBlockNumber,  # 2021-03-18 05:29:51 UTC
      londonBlock:         5_062_605.toBlockNumber,  # 2021-07-01 03:19:39 UTC
      arrowGlacierBlock:   high(BlockNumber),        # No current plan
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
