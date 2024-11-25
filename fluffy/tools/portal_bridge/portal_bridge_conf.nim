# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strutils, os, uri],
  confutils,
  confutils/std/net,
  nimcrypto/hash,
  ../../network_metadata,
  ../../eth_data/era1,
  ../../[conf, logging]

export net

proc defaultEthDataDir*(): string =
  let dataDir =
    when defined(windows):
      "AppData" / "Roaming" / "EthData"
    elif defined(macosx):
      "Library" / "Application Support" / "EthData"
    else:
      ".cache" / "eth-data"

  getHomeDir() / dataDir

proc defaultEra1DataDir*(): string =
  defaultEthDataDir() / "era1"

proc defaultPortalBridgeStateDir*(): string =
  when defined(windows) or defined(macosx):
    defaultDataDir() / "Bridge" / "State"
  else:
    defaultDataDir() / "bridge" / "state"

const defaultEndEra* = uint64(era(network_metadata.mergeBlockNumber - 1))

type
  TrustedDigest* = MDigest[32 * 8]

  JsonRpcUrlKind* = enum
    HttpUrl
    WsUrl

  JsonRpcUrl* = object
    kind*: JsonRpcUrlKind
    value*: string

  PortalBridgeCmd* = enum
    beacon = "Run a Portal bridge for the beacon network"
    history = "Run a Portal bridge for the history network"
    state = "Run a Portal bridge for the state network"

  PortalBridgeConf* = object # Logging
    logLevel* {.desc: "Sets the log level", defaultValue: "INFO", name: "log-level".}:
      string

    logStdout* {.
      hidden,
      desc:
        "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)",
      defaultValueDesc: "auto",
      defaultValue: StdoutLogKind.Auto,
      name: "log-format"
    .}: StdoutLogKind

    portalRpcUrl* {.
      desc: "Portal node JSON-RPC API URL",
      defaultValue: JsonRpcUrl(kind: HttpUrl, value: "http://127.0.0.1:8545"),
      name: "portal-rpc-url"
    .}: JsonRpcUrl

    case cmd* {.command, desc: "".}: PortalBridgeCmd
    of PortalBridgeCmd.beacon:
      # Beacon node REST API URL
      restUrl* {.
        desc: "URL of the beacon node REST service",
        defaultValue: "http://127.0.0.1:5052",
        name: "rest-url"
      .}: string

      # Backfill options
      backfillAmount* {.
        desc: "Amount of beacon LC updates to backfill gossip into the network",
        defaultValue: 64,
        name: "backfill-amount"
      .}: uint64

      trustedBlockRoot* {.
        desc:
          "Trusted finalized block root for which to gossip a LC bootstrap into the network",
        defaultValue: none(TrustedDigest),
        name: "trusted-block-root"
      .}: Option[TrustedDigest]
    of PortalBridgeCmd.history:
      web3Url* {.desc: "Execution layer JSON-RPC API URL", name: "web3-url".}:
        JsonRpcUrl

      blockVerify* {.
        desc: "Verify the block header, body and receipts",
        defaultValue: false,
        name: "block-verify"
      .}: bool

      latest* {.
        desc:
          "Follow the head of the chain and gossip latest block header, body and receipts into the network",
        defaultValue: true,
        name: "latest"
      .}: bool

      backfill* {.
        desc:
          "Randomly backfill pre-merge block headers, bodies and receipts into the network from the era1 files",
        defaultValue: false,
        name: "backfill"
      .}: bool

      startEra* {.desc: "The era to start from", defaultValue: 0, name: "start-era".}:
        uint64

      endEra* {.
        desc: "The era to stop at", defaultValue: defaultEndEra, name: "end-era"
      .}: uint64

      audit* {.
        desc:
          "Run pre-merge backfill in audit mode, which will only gossip content that if failed to fetch from the network",
        defaultValue: true,
        name: "audit"
      .}: bool

      era1Dir* {.
        desc: "The directory where all era1 files are stored",
        defaultValue: defaultEra1DataDir(),
        defaultValueDesc: defaultEra1DataDir(),
        name: "era1-dir"
      .}: InputDir

      gossipConcurrency* {.
        desc:
          "The number of concurrent gossip workers for gossiping content into the portal network",
        defaultValue: 50,
        name: "gossip-concurrency"
      .}: int
    of PortalBridgeCmd.state:
      web3UrlState* {.desc: "Execution layer JSON-RPC API URL", name: "web3-url".}:
        JsonRpcUrl

      stateDir* {.
        desc: "The directory where the state data is stored",
        defaultValue: defaultPortalBridgeStateDir(),
        defaultValueDesc: defaultPortalBridgeStateDir(),
        name: "state-dir"
      .}: InputDir

      startBlockNumber* {.
        desc: "The block number to start from", defaultValue: 1, name: "start-block"
      .}: uint64

      verifyStateProofs* {.
        desc:
          "Verify state proofs before gossiping them into the portal network (Slow: Only used for testing).",
        defaultValue: false,
        name: "verify-state-proofs"
      .}: bool

      enableGossip* {.
        desc:
          "Enable gossipping the state into the portal network. Disable to only build the state without gossiping it.",
        defaultValue: true,
        name: "enable-gossip"
      .}: bool

      gossipGenesis* {.
        desc:
          "Enable gossip of the genesis state into the portal network when starting from block 1",
        defaultValue: true,
        name: "gossip-genesis"
      .}: bool

      verifyGossip* {.
        desc:
          "Enable verifying that the state was successfully gossipped by fetching it from the network",
        defaultValue: false,
        name: "verify-gossip"
      .}: bool

      skipGossipForExisting* {.
        desc:
          "Enable skipping gossip of each content value which is successfully fetched from the network",
        defaultValue: true,
        name: "skip-gossip-for-existing"
      .}: bool

      gossipWorkersCount* {.
        desc:
          "The number of workers to use for gossiping the state into the portal network",
        defaultValue: 2,
        name: "gossip-workers"
      .}: uint

func parseCmdArg*(T: type TrustedDigest, input: string): T {.raises: [ValueError].} =
  TrustedDigest.fromHex(input)

func completeCmdArg*(T: type TrustedDigest, input: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type JsonRpcUrl, p: string): T {.raises: [ValueError].} =
  let
    url = parseUri(p)
    normalizedScheme = url.scheme.toLowerAscii()

  if (normalizedScheme == "http" or normalizedScheme == "https"):
    JsonRpcUrl(kind: HttpUrl, value: p)
  elif (normalizedScheme == "ws" or normalizedScheme == "wss"):
    JsonRpcUrl(kind: WsUrl, value: p)
  else:
    raise newException(
      ValueError,
      "The Web3 URL must specify one of following protocols: http/https/ws/wss",
    )

proc completeCmdArg*(T: type JsonRpcUrl, val: string): seq[string] =
  return @[]
