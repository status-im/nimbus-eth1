# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  confutils,
  confutils/std/net,
  nimcrypto/hash,
  ../logging,
  ./common/rpc_helpers,
  ../../execution_chain/common/chain_config

export net, rpc_helpers, chain_config

const supportedNetworks* =
  [("mainnet", MainNet), ("sepolia", SepoliaNet), ("hoodi", HoodiNet)]

type
  BackfillMode* = enum
    none
    regular
    sync
    audit

  TrustedDigest* = MDigest[32 * 8]

  PortalBridgeCmd* = enum
    beacon = "Run a Portal bridge for the beacon network"
    history = "Run a Portal bridge for the history network"

  PortalBridgeConf* = object # Logging
    logLevel* {.desc: "Sets the log level", defaultValue: "INFO", name: "log-level".}:
      string

    logFormat* {.
      desc: "Choice of log format (auto, colors, nocolors, json)",
      defaultValueDesc: "auto",
      defaultValue: StdoutLogKind.Auto,
      name: "log-format"
    .}: StdoutLogKind

    portalRpcUrl* {.
      desc: "Portal node JSON-RPC API URL",
      defaultValue: JsonRpcUrl(kind: HttpUrl, value: "http://127.0.0.1:8565"),
      name: "portal-rpc-url"
    .}: JsonRpcUrl

    network* {.
      desc: "Name of Ethereum network (mainnet, sepolia, hoodi)",
      defaultValue: "mainnet",
      defaultValueDesc: "mainnet",
      name: "network"
    .}: string

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
      web3Url* {.
        desc: "Execution layer JSON-RPC API URL",
        defaultValue: JsonRpcUrl(kind: HttpUrl, value: "http://127.0.0.1:8545"),
        name: "web3-url"
      .}: JsonRpcUrl

      blockVerify* {.
        desc:
          "Verify the block body and receipts against the received header. Does not verify against the chain.",
        defaultValue: false,
        name: "block-verify"
      .}: bool

      latest* {.
        desc:
          "Follow the head of the chain and gossip latest block body and receipts into the network. Requires web3-url to be set.",
        defaultValue: false,
        name: "latest"
      .}: bool

      backfillMode* {.
        desc:
          "Backfill mode to use for the history bridge. Requires access to era1 or ere files.",
        longDesc:
          "Valid values:\n" & "  none    — backfill disabled\n" &
          "  regular — Gossip all block bodies and receipts from era1 or ere files\n" &
          "  sync    — Download all block bodies and receipts and gossip missing content\n" &
          "  audit   — Download randomly sampled block bodies and receipts and gossip missing content",
        defaultValue: BackfillMode.regular,
        name: "backfill-mode"
      .}: BackfillMode

      backfillLoop* {.
        desc:
          "Restart the backfill loop when it finishes (only applies to sync and regular modes)",
        defaultValue: true,
        name: "backfill-loop"
      .}: bool

      era* {.desc: "Number of first era to process", defaultValue: 0, name: "era".}:
        uint64

      eraCount* {.
        desc: "Number of eras to process (0 = all available)",
        defaultValue: 0,
        name: "era-count"
      .}: uint64

      ereDir* {.
        desc: "The directory where ere files are stored (preferred source)",
        defaultValue: none(InputDir),
        name: "ere-dir"
      .}: Option[InputDir]

      era1Dir* {.
        desc:
          "The directory where era1 files are stored (legacy fallback when --ere-dir is not set)",
        defaultValue: none(InputDir),
        name: "era1-dir"
      .}: Option[InputDir]

      gossipConcurrency* {.
        desc:
          "The number of concurrent gossip workers for gossiping content into the portal network",
        defaultValue: 50,
        name: "gossip-concurrency"
      .}: int

func networkId*(config: PortalBridgeConf): NetworkId =
  let networkLower = config.network.toLowerAscii()
  for (name, id) in supportedNetworks:
    if name == networkLower:
      return id
  raiseAssert "Unsupported network: " & config.network

func parseCmdArg*(T: type TrustedDigest, input: string): T {.raises: [ValueError].} =
  TrustedDigest.fromHex(input)

func completeCmdArg*(T: type TrustedDigest, input: string): seq[string] =
  return @[]
