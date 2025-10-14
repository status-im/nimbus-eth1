# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/os,
  json_rpc/rpcproxy, # must be early (compilation annoyance)
  json_serialization/std/net,
  beacon_chain/conf_light_client,
  beacon_chain/nimbus_binary_common

export net

type
  Web3UrlKind* = enum
    HttpUrl
    WsUrl

  Web3Url* = object
    kind*: Web3UrlKind
    web3Url*: string

#!fmt: off
type VerifiedProxyConf* = object
  # Config
  configFile* {.
    desc: "Loads the configuration from a TOML file"
    name: "config-file" .}: Option[InputFile]

  # Logging
  logLevel* {.
    desc: "Sets the log level"
    defaultValue: "INFO"
    name: "log-level" .}: string

  logStdout* {.
    hidden
    desc: "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)"
    defaultValueDesc: "auto"
    defaultValue: StdoutLogKind.Auto
    name: "log-format" .}: StdoutLogKind

  # Storage
  dataDirFlag* {.
    desc: "The directory where nimbus will store all blockchain data"
    abbr: "d"
    name: "data-dir" .}: Option[OutDir]

  # Network
  eth2Network* {.
    desc: "The Eth2 network to join"
    defaultValueDesc: "mainnet"
    name: "network" .}: Option[string]

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

  # Consensus light sync
  # No default - Needs to be provided by the user
  trustedBlockRoot* {.
    desc: "Recent trusted finalized block root to initialize light client from"
    name: "trusted-block-root" .}: Eth2Digest

  # (Untrusted) web3 provider
  # No default - Needs to be provided by the user
  backendUrl* {.
    desc: "URL of the web3 data provider",
    name: "backend-url"
  .}: Web3Url

  # Listening endpoint of the proxy
  # (verified) web3 end
  frontendUrl* {.
    desc: "URL for the listening end of the proxy - [http/ws]://[address]:[port]",
    defaultValue: Web3Url(kind: HttpUrl, web3Url: "http://127.0.0.1:8545"),
    defaultValueDesc: "http://127.0.0.1:8545",
    name: "frontend-url"
  .}: Web3Url

  # (Untrusted) web3 provider
  # No default - Needs to be provided by the user
  lcEndpoint* {.
    desc: "command seperated URLs of the light client data provider",
    name: "lc-endpoint"
  .}: string

#!fmt: on

proc parseCmdArg*(T: type Web3Url, p: string): T {.raises: [ValueError].} =
  let
    url = parseUri(p)
    normalizedScheme = url.scheme.toLowerAscii()

  if (normalizedScheme == "http" or normalizedScheme == "https"):
    Web3Url(kind: HttpUrl, web3Url: p)
  elif (normalizedScheme == "ws" or normalizedScheme == "wss"):
    Web3Url(kind: WsUrl, web3Url: p)
  else:
    raise newException(
      ValueError, "Web3 url should have defined scheme (http/https/ws/wss)"
    )

proc completeCmdArg*(T: type Web3Url, val: string): seq[string] =
  return @[]

# TODO: Cannot use ClientConfig in VerifiedProxyConf due to the fact that
# it contain `set[TLSFlags]` which does not have proper toml serialization
func asClientConfig*(url: Web3Url): ClientConfig =
  case url.kind
  of HttpUrl:
    getHttpClientConfig(url.web3Url)
  of WsUrl:
    getWebSocketClientConfig(url.web3Url, flags = {})
