# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/[os, strutils, uri], confutils, chronicles, beacon_chain/spec/digest

proc defaultDataDir*(): string =
  let dataDir =
    when defined(windows):
      "AppData" / "Roaming" / "EthData"
    elif defined(macosx):
      "Library" / "Application Support" / "EthData"
    else:
      ".cache" / "eth-data"

  getHomeDir() / dataDir

type
  Web3UrlKind* = enum
    HttpUrl
    WsUrl

  Web3Url* = object
    kind*: Web3UrlKind
    url*: string

const
  defaultDataDirDesc* = defaultDataDir()
  defaultWeb3Url* = Web3Url(kind: HttpUrl, url: "http://127.0.0.1:8545")

type
  ExporterCmd* = enum
    history
    beacon

  HistoryCmd* = enum
    exportBlockData = "Export block data (headers, bodies and receipts) to a yaml file"

  BeaconCmd* = enum
    exportLCBootstrap = "Export Light Client Bootstrap"
    exportLCUpdates = "Export Light Client Updates"
    exportLCFinalityUpdate = "Export Light Client Finality Update"
    exportLCOptimisticUpdate = "Export Light Client Optimistic Update"
    exportHistoricalRoots = "Export historical roots from the beacon state (SSZ format)"
    exportBlockProof = "Export EL block proof from era files (Bellatrix and later)"

  ExporterConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO, desc: "Sets the log level", name: "log-level"
    .}: LogLevel
    dataDir* {.
      desc: "The directory where generated data files will be exported to",
      defaultValue: defaultDataDir(),
      defaultValueDesc: $defaultDataDirDesc,
      name: "data-dir"
    .}: OutDir
    network* {.
      desc: "Name of Ethereum network (mainnet, sepolia, hoodi)",
      defaultValue: "mainnet",
      defaultValueDesc: "mainnet",
      name: "network"
    .}: string
    case cmd* {.command.}: ExporterCmd
    of ExporterCmd.history:
      web3Url* {.
        desc: "Execution layer JSON-RPC API URL",
        defaultValue: defaultWeb3Url,
        name: "web3-url"
      .}: Web3Url
      case historyCmd* {.command.}: HistoryCmd
      of exportBlockData:
        blockNumber* {.
          desc: "Number of the block to be exported",
          defaultValue: 0,
          name: "blocknumber"
        .}: uint64
    of ExporterCmd.beacon:
      restUrl* {.
        desc: "URL of the beacon node REST service",
        defaultValue: "http://127.0.0.1:5052",
        name: "rest-url"
      .}: string
      case beaconCmd* {.command.}: BeaconCmd
      of exportLCBootstrap:
        trustedBlockRoot* {.
          desc: "Trusted finalized block root of the requested bootstrap",
          name: "trusted-block-root"
        .}: Eth2Digest
      of exportLCUpdates:
        startPeriod* {.
          desc: "Period of the first LC update", defaultValue: 0, name: "start-period"
        .}: uint64
        count* {.
          desc: "Amount of LC updates to request", defaultValue: 1, name: "count"
        .}: uint64
      of exportLCFinalityUpdate:
        discard
      of exportLCOptimisticUpdate:
        discard
      of exportHistoricalRoots:
        discard
      of exportBlockProof:
        slotNumber* {.
          desc: "The slot for which to export the beacon block proof", name: "slot"
        .}: uint64
        eraDir* {.desc: "Directory containing era files", name: "era-dir".}: InputDir

proc parseCmdArg*(T: type Web3Url, p: string): T {.raises: [ValueError].} =
  let
    url = parseUri(p)
    normalizedScheme = url.scheme.toLowerAscii()

  if (normalizedScheme == "http" or normalizedScheme == "https"):
    Web3Url(kind: HttpUrl, url: p)
  elif (normalizedScheme == "ws" or normalizedScheme == "wss"):
    Web3Url(kind: WsUrl, url: p)
  else:
    raise newException(
      ValueError,
      "The Web3 URL must specify one of following protocols: http/https/ws/wss",
    )

proc completeCmdArg*(T: type Web3Url, val: string): seq[string] =
  return @[]

func parseCmdArg*(
    T: type Eth2Digest, input: string
): T {.raises: [ValueError, Defect].} =
  Eth2Digest.fromHex(input)

func completeCmdArg*(T: type Eth2Digest, input: string): seq[string] =
  return @[]
