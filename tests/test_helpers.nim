# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, macros, json, strformat, strutils, tables],
  stew/byteutils, net, eth/[common/keys, p2p], unittest2,
  testutils/markdown_reports,
  ../execution_chain/[constants, config, transaction, errors],
  ../execution_chain/db/ledger,
  ../execution_chain/common/[context, common]

func revTable(list: array[EVMFork, string]): Table[string, EVMFork] =
  for k, v in list:
    result[v] = k

const
  # from https://ethereum-tests.readthedocs.io/en/latest/test_types/state_tests.html
  ForkToName: array[EVMFork, string] = [
    "Frontier",             # FkFrontier
    "Homestead",            # FkHomestead
    "EIP150",               # FkTangerine
    "EIP158",               # FkSpurious
    "Byzantium",            # FkByzantium
    "Constantinople",       # FkConstantinople
    "ConstantinopleFix",    # FkPetersburg
    "Istanbul",             # FkIstanbul
    "Berlin",               # FkBerlin
    "London",               # FkLondon
    "Merge",                # FkParis
    "Shanghai",             # FkShanghai
    "Cancun",               # FkCancun
    "Prague",               # FkPrague
    "Osaka",                # FkOsaka
  ]

  nameToFork* = ForkToName.revTable

func skipNothing*(folder: string, name: string): bool = false

var status = initOrderedTable[string, OrderedTable[string, Status]]()

proc jsonTestImpl*(inputFolder, outputName: string, handler, skipTest: NimNode): NimNode {.compileTime.} =
  let
    testStatusIMPL = ident("testStatusIMPL")
    # workaround for strformat in quote do: https://github.com/nim-lang/Nim/issues/8220
    symbol {.used.} = newIdentNode"symbol"
    final  {.used.} = newIdentNode"final"
    name   {.used.} = newIdentNode"name"
    formatted {.used.} = newStrLitNode"{symbol[final]} {name:<64}{$final}{'\n'}"

  result = quote:
    var filenames: seq[string] = @[]
    let inputPath = "tests" / "fixtures" / `inputFolder`
    for filename in walkDirRec(inputPath):
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
      let filename = fname
      test fname.substr(inputPath.len + 1):
        {.gcsafe.}:
          let
            (folder, name) = filename.splitPath()
            last = folder.splitPath().tail
          # we set this here because exceptions might be raised in the handler:
          status[last][name] = Status.Fail
          let fixtures = parseJson(readFile(filename))
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

proc verifyLedger*(wantedState: JsonNode, ledger: ReadOnlyLedger) =
  for ac, accountData in wantedState:
    let account = EthAddress.fromHex(ac)
    for slot, value in accountData{"storage"}:
      let
        slotId = UInt256.fromHex slot
        wantedValue = UInt256.fromHex value.getStr

      let actualValue = ledger.getStorage(account, slotId)
      #if not found:
      #  raise newException(ValidationError, "account not found:  " & ac)
      if actualValue != wantedValue:
        raise newException(ValidationError, &"{ac} storageDiff: [{slot}] {actualValue.toHex} != {wantedValue.toHex}")

    let
      wantedCode = hexToSeqByte(accountData{"code"}.getStr)
      wantedBalance = UInt256.fromHex accountData{"balance"}.getStr
      wantedNonce = accountData{"nonce"}.getHexadecimalInt.AccountNonce

      actualCode = ledger.getCode(account).bytes()
      actualBalance = ledger.getBalance(account)
      actualNonce = ledger.getNonce(account)

    if wantedCode != actualCode:
      raise newException(ValidationError, &"{ac} codeDiff {wantedCode.toHex} != {actualCode.toHex}")
    if wantedBalance != actualBalance:
      raise newException(ValidationError, &"{ac} balanceDiff {wantedBalance.toHex} != {actualBalance.toHex}")
    if wantedNonce != actualNonce:
      raise newException(ValidationError, &"{ac} nonceDiff {wantedNonce.toHex} != {actualNonce.toHex}")

proc setupEthNode*(
    conf: NimbusConf, ctx: EthContext,
    capabilities: varargs[ProtocolInfo, `protocolInfo`]): EthereumNode =
  let keypair = ctx.getNetKeys(conf.netKey, conf.dataDir.string).tryGet()
  let srvAddress = enode.Address(
    ip: conf.listenAddress, tcpPort: conf.tcpPort, udpPort: conf.udpPort)

  var node = newEthereumNode(
    keypair, srvAddress,
    conf.networkId,
    conf.agentString,
    addAllCapabilities = false,
    bindUdpPort = conf.udpPort, bindTcpPort = conf.tcpPort)

  for capability in capabilities:
    node.addCapability capability

  node

proc makeTestConfig*(): NimbusConf =
  # commandLineParams() will not works inside all_tests
  makeConfig(@[])
