# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[strutils, macros],
  std/os,
  stew/[byteutils, io2],
  stint,
  eth/common,
  eth/common/eth_types_json_serialization,
  json_serialization,
  json_serialization/pkg/results,
  json_serialization/std/tables,
  json_serialization/lexer,
  chronicles,
  results,
  ./[chain_config, hardforks]

export chain_config

# JGenesis JSON flavor

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

# Custom readers for the JGenesis flavor

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
    "osaka",
    "bpo1",
    "bpo2",
    "bpo3",
    "bpo4",
    "bpo5",
    "amsterdam",
    "bogota",
  ]

func ofStmt(fork: HardFork, keyName: string, reader: NimNode, value: NimNode): NimNode =
  let branchStmt = quote do:
    `value`[`fork`] = `reader`.readValue(Opt[BlobSchedule])

  nnkOfBranch.newTree(
    newLit(keyName),
    branchStmt
  )

macro blobScheduleParser(reader, key, value: typed): untyped =
  # Automated blob schedule parser generator
  var caseStmt = nnkCaseStmt.newTree(
    quote do: toLowerAscii(`key`)
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

# Blob-schedule post-processing

macro blobScheduleActivation(conf: typed): untyped =
  # Automated blob schedule parser generator
  var res = nnkBracket.newTree
  for fork in Cancun..HardFork.high:
    let activationName = BlobScheduleTable[fork] & "Time"
    let fieldIdent = newIdentNode(activationName)
    res.add quote do:
      `conf`.`fieldIdent`

  res

proc configureBlobSchedule(conf: ChainConfig) =
  if conf.blobSchedule[Cancun].isNone:
    conf.blobSchedule[Cancun] = Opt.some(BlobSchedule(target: 3'u64, max: 6'u64, baseFeeUpdateFraction: 3_338_477'u64))
  else:
    if conf.blobSchedule[Cancun].value.baseFeeUpdateFraction == 0:
      conf.blobSchedule[Cancun].value.baseFeeUpdateFraction = 3_338_477'u64

  let blobScheduleTime: array[Cancun..HardFork.high, Opt[EthTime]] = blobScheduleActivation(conf)

  var prevFork = Cancun
  for fork in Prague..HardFork.high:
    if conf.blobSchedule[fork].isNone:
      conf.blobSchedule[fork] = conf.blobSchedule[prevFork]
    if conf.blobSchedule[fork].value.baseFeeUpdateFraction == 0:
      # Set fallback to Cancun's baseFeeUpdateFraction and prevent division by zero
      warn "baseFeeUpdateFraction not set, fallback to Cancun's", fork=fork
      conf.blobSchedule[fork].value.baseFeeUpdateFraction = 3_338_477'u64
    if blobScheduleTime[fork].isSome:
      prevFork = fork

# Genesis / network-params file loading

proc parseGenesis(data: string): Genesis
     {.gcsafe.} =
  try:
    result = JGenesis.decode(data, Genesis, allowUnknownFields = true)
  except SerializationError as e:
    error "Invalid genesis config file format", msg=e.formatMsg("")
    return nil

proc loadGenesisFromFile(fileName: string, withError = true): Genesis
     {.gcsafe.} =
  try:
    result = JGenesis.loadFile(fileName, Genesis, allowUnknownFields = true)
  except IOError as e:
    if withError:
      error "Genesis I/O error", fileName, msg=e.msg
    return nil
  except SerializationError as e:
    if withError:
      error "Invalid genesis config file format", msg=e.formatMsg("")
    return nil

proc loadGenesisFromFolder(inputPath: string): Genesis =
  # first we try with "genesis.json"
  var genesis = loadGenesisFromFile(inputPath & "/genesis.json", withError = false)
  if genesis.isNil.not:
    return genesis

  # if there is no "genesis.json", we try to load any json file
  try:
    for fileName in walkDirRec(inputPath):
      if not fileName.endsWith(".json"):
        continue
      genesis = loadGenesisFromFile(fileName, withError = false)
      if genesis.isNil.not:
        return genesis
    error "No valid genesis.json found", path=inputPath
    nil
  except OSError as exc:
    error "Error when looking for genesis file", path=inputPath, msg=exc.msg
    nil

proc loadGenesis(inputPath: string): Genesis =
  if isDir(inputPath):
    loadGenesisFromFolder(inputPath)
  else:
    loadGenesisFromFile(inputPath)

proc validateNetworkParams(params: var NetworkParams, input: string, inputIsFile: bool): bool =
  if params.genesis.isNil:
    # lets try with geth's format
    let genesis = if inputIsFile: loadGenesis(input)
                  else: parseGenesis(input)
    if genesis.isNil:
      return false
    params.genesis = genesis

  if params.config.isNil:
    warn "Loaded custom network contains no 'config' data"
    params.config = ChainConfig()

  configureBlobSchedule(params.config)
  validateChainConfig(params.config)

proc loadNetworkParamsFromFile(fileName: string, params: var NetworkParams, withError = true): bool =
  try:
    params = JGenesis.loadFile(fileName, NetworkParams, allowUnknownFields = true)
    true
  except IOError as e:
    if withError:
      error "Network params I/O error", fileName, msg=e.msg
    false
  except SerializationError as e:
    if withError:
      error "Invalid network params file format", fileName, msg=e.formatMsg("")
    false

proc loadNetworkParamsFromFolder(inputPath: string, params: var NetworkParams): bool =
  # first we try with "genesis.json"
  if loadNetworkParamsFromFile(inputPath & "/genesis.json", params, withError = false):
    return true

  # if there is no "genesis.json", we try to load any json file
  try:
    for fileName in walkDirRec(inputPath):
      if not fileName.endsWith(".json"):
        continue
      if loadNetworkParamsFromFile(fileName, params, withError = false):
        return true
    error "No valid genesis.json found", path=inputPath
    false
  except OSError as exc:
    error "Error when looking for genesis file", path=inputPath, msg=exc.msg
    false

proc loadNetworkParams*(inputPath: string, params: var NetworkParams): bool =
  if isDir(inputPath):
    if not loadNetworkParamsFromFolder(inputPath, params):
      return false
  else:
    if not loadNetworkParamsFromFile(inputPath, params):
      return false

  validateNetworkParams(params, inputPath, true)

proc decodeNetworkParams*(jsonString: string, params: var NetworkParams): bool =
  try:
    params = JGenesis.decode(jsonString, NetworkParams, allowUnknownFields = true)
  except SerializationError as e:
    error "Invalid network params format", msg=e.formatMsg("")
    return false

  validateNetworkParams(params, jsonString, false)
