# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  os, macros, json, strformat, strutils, parseutils, os, tables,
  stew/byteutils, net, eth/[common, keys, rlp, p2p], unittest2,
  testutils/markdown_reports,
  ../nimbus/[constants, config, transaction, utils, errors, forks],
  ../nimbus/db/accounts_cache,
  ../nimbus/context

func revmap(x: Table[Fork, string]): Table[string, Fork] =
  result = initTable[string, Fork]()
  for k, v in x:
    result[v] = k

const
  # from https://ethereum-tests.readthedocs.io/en/latest/test_types/state_tests.html
  forkNames* = {
    FkFrontier: "Frontier",
    FkHomestead: "Homestead",
    FkTangerine: "EIP150",
    FkSpurious: "EIP158",
    FkByzantium: "Byzantium",
    FkConstantinople: "Constantinople",
    FkPetersburg: "ConstantinopleFix",
    FkIstanbul: "Istanbul",
    FkBerlin: "Berlin",
    FkLondon: "London"
  }.toTable

  supportedForks* = {
    FkFrontier,
    FkHomestead,
    FkTangerine,
    FkSpurious,
    FkByzantium,
    FkConstantinople,
    FkPetersburg,
    FkIstanbul,
    FkBerlin,
    FkLondon}

  nameToFork* = revmap(forkNames)

func skipNothing*(folder: string, name: string): bool = false

proc lacksSupportedForks*(fixtures: JsonNode): bool =
  # XXX: Until Nimbus supports all forks, some of the GeneralStateTests won't work.

  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break

  # not all fixtures make a distinction between forks, so default to accepting
  # them all, until we find the ones that specify forks in their "post" section
  result = false
  if fixture.kind == JObject and fixture.hasKey("transaction") and fixture.hasKey("post"):
    result = true
    for fork in supportedForks:
      if fixture["post"].hasKey(forkNames[fork]):
        result = false
        break

var status = initOrderedTable[string, OrderedTable[string, Status]]()

proc jsonTestImpl*(inputFolder, outputName: string, handler, skipTest: NimNode): NimNode {.compileTime.} =
  let
    testStatusIMPL = ident("testStatusIMPL")
    testName = ident("testName")
    # workaround for strformat in quote do: https://github.com/nim-lang/Nim/issues/8220
    symbol {.used.} = newIdentNode"symbol"
    final  {.used.} = newIdentNode"final"
    name   {.used.} = newIdentNode"name"
    formatted {.used.} = newStrLitNode"{symbol[final]} {name:<64}{$final}{'\n'}"

  result = quote:
    var filenames: seq[string] = @[]
    for filename in walkDirRec("tests" / "fixtures" / `inputFolder`):
      if not filename.endsWith(".json"):
        continue
      var (folder, name) = filename.splitPath()
      let last = folder.splitPath().tail
      if not status.hasKey(last):
        status[last] = initOrderedTable[string, Status]()
      status[last][name] = Status.Skip
      if `skipTest`(last, name):
        continue
      filenames.add(filename)

    doAssert(filenames.len > 0)
    for fname in filenames:
      test fname:
        {.gcsafe.}:
          let
            filename = `testName` # the first argument passed to the `test` template
            (folder, name) = filename.splitPath()
            last = folder.splitPath().tail
          # we set this here because exceptions might be raised in the handler:
          status[last][name] = Status.Fail
          let fixtures = parseJson(readFile(filename))
          if fixtures.lacksSupportedForks:
            status[last][name] = Status.Skip
            skip()
          else:
            # when not paralleliseTests:
            #   echo filename
            `handler`(fixtures, `testStatusIMPL`)
            if `testStatusIMPL` == OK:
              status[last][name] = Status.OK
            elif `testStatusIMPL` == SKIPPED:
              status[last][name] = Status.Skip

    suiteTeardown:
      status.sort do (a: (string, OrderedTable[string, Status]),
                      b: (string, OrderedTable[string, Status])) -> int: cmp(a[0], b[0])

      generateReport(`outputName`, status)
      status.clear()

macro jsonTest*(inputFolder, outputName: static[string], handler: untyped, skipTest: untyped = skipNothing): untyped =
  result = jsonTestImpl(inputFolder, outputName, handler, skipTest)

macro jsonTest*(inputFolder: static[string], handler: untyped, skipTest: untyped = skipNothing): untyped =
  result = jsonTestImpl(inputFolder, inputFolder, handler, skipTest)

func ethAddressFromHex*(s: string): EthAddress = hexToByteArray(s, result)

func safeHexToSeqByte*(hexStr: string): seq[byte] =
  if hexStr == "":
    @[]
  else:
    hexStr.hexToSeqByte

func getHexadecimalInt*(j: JsonNode): int64 =
  # parseutils.parseHex works with int which will overflow in 32 bit
  var data: StUint[64]
  data = fromHex(StUint[64], j.getStr)
  result = cast[int64](data)

proc setupStateDB*(wantedState: JsonNode, stateDB: AccountsCache) =
  for ac, accountData in wantedState:
    let account = ethAddressFromHex(ac)
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, fromHex(UInt256, slot), fromHex(UInt256, value.getStr))

    let nonce = accountData{"nonce"}.getHexadecimalInt.AccountNonce
    let code = accountData{"code"}.getStr.safeHexToSeqByte
    let balance = UInt256.fromHex accountData{"balance"}.getStr

    stateDB.setNonce(account, nonce)
    stateDB.setCode(account, code)
    stateDB.setBalance(account, balance)

proc verifyStateDB*(wantedState: JsonNode, stateDB: ReadOnlyStateDB) =
  for ac, accountData in wantedState:
    let account = ethAddressFromHex(ac)
    for slot, value in accountData{"storage"}:
      let
        slotId = UInt256.fromHex slot
        wantedValue = UInt256.fromHex value.getStr

      let actualValue = stateDB.getStorage(account, slotId)
      #if not found:
      #  raise newException(ValidationError, "account not found:  " & ac)
      if actualValue != wantedValue:
        raise newException(ValidationError, &"{ac} storageDiff: [{slot}] {actualValue.toHex} != {wantedValue.toHex}")

    let
      wantedCode = hexToSeqByte(accountData{"code"}.getStr)
      wantedBalance = UInt256.fromHex accountData{"balance"}.getStr
      wantedNonce = accountData{"nonce"}.getHexadecimalInt.AccountNonce

      actualCode = stateDB.getCode(account)
      actualBalance = stateDB.getBalance(account)
      actualNonce = stateDB.getNonce(account)

    if wantedCode != actualCode:
      raise newException(ValidationError, &"{ac} codeDiff {wantedCode.toHex} != {actualCode.toHex}")
    if wantedBalance != actualBalance:
      raise newException(ValidationError, &"{ac} balanceDiff {wantedBalance.toHex} != {actualBalance.toHex}")
    if wantedNonce != actualNonce:
      raise newException(ValidationError, &"{ac} nonceDiff {wantedNonce.toHex} != {actualNonce.toHex}")

proc parseAccessList(n: JsonNode): AccessList =
  if n.kind == JNull:
    return

  for x in n:
    var ap = AccessPair(
      address: parseAddress(x["address"].getStr)
    )
    let sks = x["storageKeys"]
    for sk in sks:
      ap.storageKeys.add hexToByteArray[32](sk.getStr())
    result.add ap

proc getFixtureTransaction*(j: JsonNode, dataIndex, gasIndex, valueIndex: int): Transaction =
  let dynamicFeeTx = "gasPrice" notin j
  let nonce    = j["nonce"].getHexadecimalInt.AccountNonce
  let gasLimit = j["gasLimit"][gasIndex].getHexadecimalInt

  var toAddr: Option[EthAddress]
  # Fixture transactions with `"to": ""` are contract creations.
  #
  # Fixture transactions with `"to": "0x..."` or `"to": "..."` where `...` are
  # 40 hex digits are call/transfer transactions.  Even if the digits are all
  # zeros, because the all-zeros address is a legitimate account.
  #
  # There are no other formats.  The number of digits if present is always 40,
  # "0x" prefix is used in some but not all fixtures, and upper case hex digits
  # occur in a few.
  let rawTo = j["to"].getStr
  if rawTo != "":
    toAddr = some(rawTo.parseAddress)

  let hexStr = j["value"][valueIndex].getStr
  # stTransactionTest/ValueOverflow.json
  # prevent parsing exception and subtitute it with max uint256
  let value = if ':' in hexStr: high(UInt256) else: fromHex(UInt256, hexStr)
  let payload = j["data"][dataIndex].getStr.safeHexToSeqByte

  var secretKey = j["secretKey"].getStr
  removePrefix(secretKey, "0x")
  let privateKey = PrivateKey.fromHex(secretKey).tryGet()

  if dynamicFeeTx:
    let accList = j["accessLists"][dataIndex]
    var tx = Transaction(
      txType: TxEip1559,
      nonce: nonce,
      maxFee: j["maxFeePerGas"].getHexadecimalInt,
      maxPriorityFee: j["maxPriorityFeePerGas"].getHexadecimalInt,
      gasLimit: gasLimit,
      to: toAddr,
      value: value,
      payload: payload,
      accessList: parseAccessList(accList),
      chainId: ChainId(1)
    )
    return signTransaction(tx, privateKey, ChainId(1), false)

  let gasPrice = j["gasPrice"].getHexadecimalInt
  if j.hasKey("accessLists"):
    let accList = j["accessLists"][dataIndex]
    var tx = Transaction(
      txType: TxEip2930,
      nonce: nonce,
      gasPrice: gasPrice,
      gasLimit: gasLimit,
      to: toAddr,
      value: value,
      payload: payload,
      accessList: parseAccessList(accList),
      chainId: ChainId(1)
    )
    signTransaction(tx, privateKey, ChainId(1), false)
  else:
    var tx = Transaction(
      txType: TxLegacy,
      nonce: nonce,
      gasPrice: gasPrice,
      gasLimit: gasLimit,
      to: toAddr,
      value: value,
      payload: payload
    )
    signTransaction(tx, privateKey, ChainId(1), false)

proc hashLogEntries*(logs: seq[Log]): string =
  toLowerAscii("0x" & $keccakHash(rlp.encode(logs)))

proc setupEthNode*(
    conf: NimbusConf, ctx: EthContext,
    capabilities: varargs[ProtocolInfo, `protocolInfo`]): EthereumNode =
  let keypair = ctx.hexToKeyPair(conf.nodeKeyHex).tryGet()
  let srvAddress = Address(
    ip: conf.listenAddress, tcpPort: conf.tcpPort, udpPort: conf.udpPort)

  var node = newEthereumNode(
    keypair, srvAddress,
    conf.networkId,
    nil, conf.agentString,
    addAllCapabilities = false,
    bindUdpPort = conf.udpPort, bindTcpPort = conf.tcpPort)

  for capability in capabilities:
    node.addCapability capability

  node

proc makeTestConfig*(): NimbusConf =
  # commandLineParams() will not works inside all_tests
  makeConfig(@[])
