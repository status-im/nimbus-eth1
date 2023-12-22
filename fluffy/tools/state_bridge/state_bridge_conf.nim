# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  confutils, confutils/std/net,
  nimcrypto/hash,
  ../../logging

export net

type
  TrustedDigest* = MDigest[32 * 8]

  BeaconBridgeCmd* = enum
    noCommand

  BeaconBridgeConf* = object
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

    # Portal JSON-RPC API server to connect to
    rpcAddress* {.
      desc: "Listening address of the Portal JSON-RPC server"
      defaultValue: "127.0.0.1"
      name: "rpc-address" .}: string

    rpcPort* {.
      desc: "Listening port of the Portal JSON-RPC server"
      defaultValue: 8545
      name: "rpc-port" .}: Port

    dataDir* {.
      desc: "Data directory to lookup state data"
      defaultValue: "./vendor/portal-spec-tests/tests/mainnet/state/"
      name: "data-dir".}: string

    blockAmount* {.
      desc: "How many blocks to read during backfill"
      defaultValue: 1
      name: "block-amount".}: int

    case cmd* {.
      command
      defaultValue: noCommand .}: BeaconBridgeCmd
    of noCommand:
      discard

func parseCmdArg*(T: type TrustedDigest, input: string): T
                 {.raises: [ValueError].} =
  TrustedDigest.fromHex(input)

func completeCmdArg*(T: type TrustedDigest, input: string): seq[string] =
  return @[]
