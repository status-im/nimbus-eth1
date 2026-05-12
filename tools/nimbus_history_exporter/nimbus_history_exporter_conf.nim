# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[options, strutils, os, strformat],
  chronicles,
  confutils,
  confutils/defs,
  confutils/toml/defs as tomldefs,
  beacon_chain/buildinfo,
  beacon_chain/nimbus_binary_common,
  eth/common,
  ../../execution_chain/common/chain_config,
  ../../execution_chain/version_info

export defs, tomldefs, nimbus_binary_common, options, version_info

type
  HistoryExportCmd* {.pure.} = enum
    exportEre
    verifyEre
    verifyEreFile

  HistoryExportConf* = object
    configFile* {.
      desc: "Loads the configuration from a TOML file", name: "config-file"
    .}: Option[InputFile]

    logLevel* {.
      desc: "Sets the log level for process and topics",
      defaultValue: "INFO",
      name: "log-level"
    .}: string

    logFormat* {.
      desc: "Choice of log format (auto, colors, nocolors, json)",
      defaultValueDesc: "auto",
      defaultValue: StdoutLogKind.Auto,
      name: "log-format"
    .}: StdoutLogKind

    network* {.
      desc: "Name of Ethereum network (mainnet, sepolia)",
      defaultValue: "mainnet",
      defaultValueDesc: "mainnet",
      name: "network"
    .}: string

    eraDir* {.
      desc:
        "Directory containing beacon chain era files (.era) for building post-merge block proofs",
      name: "era-dir"
    .}: Option[InputDir]

    elDataDir* {.
      desc:
        "Nimbus execution client data directory for reading EL block data (default source; supports full history including post-merge)",
      name: "el-data-dir"
    .}: Option[InputDir]

    era1Dir* {.
      desc:
        "Directory for era1 archive files (alternative to el-data-dir; only works for pre-merge history)",
      name: "era1-dir"
    .}: Option[InputDir]

    case cmd* {.command.}: HistoryExportCmd
    of HistoryExportCmd.exportEre:
      startEra* {.desc: "Number of the first era to be exported", name: "start-era".}:
        uint64
      endEra* {.desc: "Number of the last era to be exported", name: "end-era".}: uint64
      noProofs* {.
        desc: "Omit proof entries from the ere file (produces a noproofs profile)",
        defaultValue: false,
        name: "no-proofs"
      .}: bool
      noReceipts* {.
        desc: "Omit receipt entries from the ere file (produces a noreceipts profile)",
        defaultValue: false,
        name: "no-receipts"
      .}: bool
      ereOutputDirFlag* {.
        desc: "Directory to write .ere files to",
        defaultValueDesc:
          "<el-data-dir>/ere, or current directory when using --era1-dir",
        name: "ere-dir"
      .}: Option[OutDir]
    of HistoryExportCmd.verifyEre:
      ereVerifyDir* {.
        desc: "Directory containing .ere files to verify", name: "ere-dir"
      .}: InputDir
    of HistoryExportCmd.verifyEreFile:
      ereFile* {.desc: "Path to the ere file to be verified", name: "ere-file".}:
        InputFile

proc ereOutputDir*(config: HistoryExportConf): string =
  doAssert config.cmd == HistoryExportCmd.exportEre
  if config.ereOutputDirFlag.isSome:
    string config.ereOutputDirFlag.get()
  elif config.elDataDir.isSome:
    config.elDataDir.get().string / "ere"
  else:
    "."

proc networkId*(config: HistoryExportConf): NetworkId =
  case config.network.toLowerAscii()
  of "mainnet":
    MainNet
  of "sepolia":
    SepoliaNet
  else:
    raiseAssert "Unsupported network: " & config.network
const
  NimbusCopyright* =
    "Copyright (c) 2026-" & compileYear & " Status Research & Development GmbH"
  ExporterName = "nimbus_history_exporter"
  ClientVersion* = &"{ExporterName}/{FullVersionStr}/{CpuInfo}"

proc checkConfig*(cfg: HistoryExportConf) =
  case cfg.network.toLowerAscii()
  of "mainnet", "sepolia":
    discard
  else:
    fatal "Unsupported network", network = cfg.network
    quit QuitFailure

  if cfg.cmd == HistoryExportCmd.exportEre and cfg.era1Dir.isNone and
      cfg.elDataDir.isNone:
    fatal "At least one of --era1-dir or --el-data-dir must be provided for exportEre"
    quit QuitFailure
