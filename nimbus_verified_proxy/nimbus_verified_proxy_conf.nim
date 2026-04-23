# nimbus_verified_proxy
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[strutils, uri],
  json_serialization/std/net,
  confutils/toml/defs as confTomlDefs,
  beacon_chain/spec/digest,
  beacon_chain/nimbus_binary_common

export net

type UrlList* = seq[string]

#!fmt: off
type VerifiedProxyConf* = object
  # Config
  configFile* {.
    desc: "Loads the configuration from a TOML file",
    name: "config-file"
  .}: Option[InputFile]

  # Logging
  logLevel* {.
    desc: "Sets the log level",
    defaultValue: "INFO",
    name: "log-level"
  .}: string

  logFormat* {.
    desc: "Choice of log format (auto, colors, nocolors, json)"
    defaultValueDesc: "auto",
    defaultValue: StdoutLogKind.Auto,
    name: "log-format"
  .}: StdoutLogKind

  # Network
  eth2Network* {.
    desc: "Consensus network to join (mainnet, hoodi, sepolia, custom/path)"
    defaultValueDesc: "mainnet"
    name: "network"
  .}: Option[string]

  accountCacheLen* {.
    hidden,
    desc: "Length of the accounts cache maintained in memory",
    defaultValue: 128,
    name: "debug-account-cache-len"
  .}: int

  codeCacheLen* {.
    hidden,
    desc: "Length of the code cache maintained in memory",
    defaultValue: 64,
    name: "debug-code-cache-len"
  .}: int

  storageCacheLen* {.
    hidden,
    desc: "Length of the storage cache maintained in memory",
    defaultValue: 256,
    name: "debug-storage-cache-len"
  .}: int

  headerStoreLen* {.
    hidden,
    desc: "Length of the header store maintained in memory",
    defaultValue: 256,
    name: "debug-header-store-len"
  .}: int

  maxBlockWalk* {.
    hidden,
    desc: "Maximum number of blocks that will be traversed to serve a request",
    defaultValue: 1000,
    name: "debug-max-walk"
  .}: uint64

  parallelBlockDownloads* {.
    hidden,
    desc: "Number of blocks downloaded parallely. Affects memory usage",
    defaultValue: 10,
    name: "debug-parallel-downloads"
  .}: uint64

  maxLightClientUpdates* {.
    hidden,
    desc: "Maximum number of light client updates fetched per sync round. Lower values reduce peak memory usage at the cost of slower initial sync.",
    defaultValue: 128,
    name: "debug-max-lc-updates"
  .}: uint64

  syncHeaderStore* {.
    hidden,
    desc: "Write LC optimistic/finalized headers to the header store",
    defaultValue: true,
    name: "debug-sync-header-store"
  .}: bool

  freezeAtSlot* {.
    hidden,
    desc: "Freeze beacon time at this slot (0 = real clock). For testing only.",
    defaultValue: 0'u64,
    name: "debug-freeze-at-slot"
  .}: uint64

  # Consensus light sync
  # No default - Needs to be provided by the user
  trustedBlockRoot* {.
    desc: "Recent trusted finalized block root to initialize light client from",
    name: "trusted-block-root"
  .}: Eth2Digest

  # (Untrusted) web3 provider
  # No default - Needs to be provided by the user
  executionApiUrls* {.
    desc: "URL of the web3 data provider, Multiple URLs can be specified by defining the option again on the command line.",
    name: "execution-api-url"
  .}: UrlList

  # Listening endpoint of the proxy
  # (verified) web3 end
  frontendUrls* {.
    desc: "URL for the listening end of the proxy - [http/ws]://[address]:[port]. Multiple URLs can be specified by defining the option again on the command line",
    defaultValue: @["http://127.0.0.1:8545"],
    defaultValueDesc: "http://127.0.0.1:8545",
    name: "listen-url"
  .}: UrlList

  # (Untrusted) web3 provider
  # No default - Needs to be provided by the user
  beaconApiUrls* {.
    desc: "URL of the light client data provider. Multiple URLs can be specified by defining the option again on the command line",
    name: "beacon-api-url"
  .}: UrlList

  privateTxUrls* {.
    desc: "URL of a private transaction relay (builder). eth_sendRawTransaction will be routed to these URLs instead of the regular execution API. Multiple URLs can be specified by defining the option again on the command line.",
    defaultValue: @[],
    name: "private-tx-url"
  .}: UrlList

#!fmt: on

proc parseCmdArg*(T: type UrlList, p: string): T {.raises: [ValueError].} =
  let urls = p.split(',')

  for u in urls:
    let
      parsed = parseUri(u)
      normalizedScheme = parsed.scheme.toLowerAscii()

    if normalizedScheme notin ["http", "https", "ws", "wss"]:
      raise
        newException(ValueError, "URL should have a valid scheme (http/https/ws/wss)")

  UrlList(urls)

# NOTE: this is overridden here instead of importing from beacon_chain/conf.nim to
# avoid importing miniupnpc because of the dependency chain below 
# nim-libp2p -> nim-nat-traversal -> miniupnpc
func parseCmdArg*(T: type Eth2Digest, input: string): T {.raises: [ValueError].} =
  Eth2Digest.fromHex(input)

proc completeCmdArg*(T: type UrlList, val: string): seq[string] =
  @[]
