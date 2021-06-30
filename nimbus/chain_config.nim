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
  eth/[common, rlp], stint, stew/[byteutils],
  nimcrypto/hash,
  json_serialization, chronicles,
  json_serialization/std/options as jsoptions,
  json_serialization/std/tables as jstable,
  json_serialization/lexer

type
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

    # TODO: this need to be fixed somehow
    # using `real` engine configuration
    poaEngine*          : bool

  Genesis* = object
    nonce*      : BlockNonce
    timestamp*  : EthTime
    extraData*  : seq[byte]
    gasLimit*   : GasInt
    difficulty* : DifficultyInt
    mixHash*    : Hash256
    coinbase*   : EthAddress
    alloc*      : GenesisAlloc
    baseFeePerGas*: Option[UInt256]
    
  GenesisAlloc* = Table[EthAddress, GenesisAccount]
  GenesisAccount* = object
    code*   : seq[byte]
    storage*: Table[UInt256, UInt256]
    balance*: UInt256
    nonce*  : AccountNonce

  CustomGenesis* = object
    config* : ChainConfig
    genesis*: Genesis

  AddressBalance = object
    address {.rlpCustomSerialization.}: EthAddress
    account {.rlpCustomSerialization.}: GenesisAccount

  CustomChain = object
    config : ChainOptions
    genesis: Genesis

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

proc loadCustomGenesis*(fileName: string, cg: var CustomGenesis): bool =
  var cc: CustomChain
  try:
    cc = Json.loadFile(fileName, CustomChain, allowUnknownFields = true)
  except IOError as e:
    error "Genesis config file error", fileName, msg=e.msg
    return false
  except JsonReaderError as e:
    error "Invalid genesis config file format", fileName, msg=e.formatMsg("")
    return false
  except:
    var msg = getCurrentExceptionMsg()
    error "Error loading genesis block config file", fileName, msg
    return false

  cg.genesis               = cc.genesis
  cg.config.chainId        = cc.config.chainId
  cg.config.daoForkSupport = cc.config.daoForkSupport
  cg.config.eip150Hash     = cc.config.eip150Hash

  # TODO: this need to be fixed somehow
  # using `real` engine configuration
  cg.config.poaEngine      = false

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
