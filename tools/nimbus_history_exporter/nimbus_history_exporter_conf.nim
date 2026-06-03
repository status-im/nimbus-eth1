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
    exportEreFromEra1
    verifyEre
    verifyEreFile
    exportEra1
    verifyEra1
    exportAccumulator
    printAccumulator

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
      desc: "Name of Ethereum network (mainnet, sepolia, hoodi)",
      defaultValue: "mainnet",
      defaultValueDesc: "mainnet",
      name: "network"
    .}: string

    elDataDir* {.
      desc: "Nimbus execution client data directory for reading EL block data",
      defaultValueDesc: "<data-dir>",
      name: "el-data-dir"
    .}: Option[InputDir]

    eraDir* {.
      desc:
        "Directory containing beacon chain era files (.era) for post-merge proof building or post-merge block verification",
      defaultValueDesc: "<data-dir>/era",
      name: "era-dir"
    .}: Option[InputDir]

    case cmd* {.command.}: HistoryExportCmd
    of HistoryExportCmd.exportEre:
      era* {.desc: "Number of first era to export", defaultValue: 0, name: "era".}:
        uint64
      eraCount* {.
        desc: "Number of eras to export (0 = all)", defaultValue: 0, name: "era-count"
      .}: uint64
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
        defaultValueDesc: "<el-data-dir>/ere",
        name: "ere-dir"
      .}: Option[OutDir]
    of HistoryExportCmd.exportEreFromEra1:
      era1Dir* {.
        desc: "Directory containing era1 archive files (only covers pre-merge history)",
        defaultValueDesc: "<data-dir>/era1",
        name: "era1-dir"
      .}: Option[InputDir]
      eraEra1* {.desc: "Number of first era to export", defaultValue: 0, name: "era".}:
        uint64
      eraCountEra1* {.
        desc:
          "Number of eras to export (0 = all pre-merge eras, excluding the merge era)",
        defaultValue: 0,
        name: "era-count"
      .}: uint64
      noProofsEra1* {.
        desc: "Omit proof entries from the ere file (produces a noproofs profile)",
        defaultValue: false,
        name: "no-proofs"
      .}: bool
      noReceiptsEra1* {.
        desc: "Omit receipt entries from the ere file (produces a noreceipts profile)",
        defaultValue: false,
        name: "no-receipts"
      .}: bool
      ereOutputDirFlagEra1* {.
        desc: "Directory to write .ere files to",
        defaultValueDesc: "<era1-dir>/../ere",
        name: "ere-dir"
      .}: Option[OutDir]
    of HistoryExportCmd.verifyEre:
      ereVerifyDir* {.
        desc: "Directory containing .ere files to verify", name: "ere-dir"
      .}: InputDir
    of HistoryExportCmd.verifyEreFile:
      ereFile* {.desc: "Path to the ere file to be verified", name: "ere-file".}:
        InputFile
    of HistoryExportCmd.exportEra1:
      eraEra1Export* {.
        desc: "Number of first era to export", defaultValue: 0, name: "era"
      .}: uint64
      eraCountEra1Export* {.
        desc:
          "Number of eras to export (0 = all pre-merge eras, including the merge era)",
        defaultValue: 0,
        name: "era-count"
      .}: uint64
      era1OutputDir* {.
        desc: "Directory to write .era1 files to",
        defaultValueDesc: "<data-dir>/era1",
        name: "era1-dir"
      .}: Option[OutDir]
    of HistoryExportCmd.verifyEra1:
      era1VerifyDir* {.
        desc: "Directory containing .era1 files to verify", name: "era1-dir"
      .}: InputDir
    of HistoryExportCmd.exportAccumulator:
      accumulatorOutputDir* {.
        desc: "Directory to write the accumulator SSZ file and epoch records to",
        name: "accumulator-dir"
      .}: OutDir
      writeEpochRecords* {.
        desc: "Also write individual epoch record SSZ files",
        defaultValue: false,
        name: "write-epoch-records"
      .}: bool
    of HistoryExportCmd.printAccumulator:
      accumulatorFile* {.
        desc: "Path to the accumulator SSZ file to print", name: "accumulator-file"
      .}: InputFile

proc eraDirPath*(config: HistoryExportConf): string =
  if config.eraDir.isSome:
    config.eraDir.get().string
  else:
    defaultDataDir("", config.network) / "era"

proc elDataDirPath*(config: HistoryExportConf): string =
  if config.elDataDir.isSome:
    config.elDataDir.get().string
  else:
    defaultDataDir("", config.network)

proc era1DirPath*(config: HistoryExportConf): string =
  doAssert config.cmd == HistoryExportCmd.exportEreFromEra1
  if config.era1Dir.isSome:
    config.era1Dir.get().string
  else:
    defaultDataDir("", config.network) / "era1"

proc era1OutputDirPath*(config: HistoryExportConf): string =
  doAssert config.cmd == HistoryExportCmd.exportEra1
  if config.era1OutputDir.isSome:
    string config.era1OutputDir.get()
  else:
    defaultDataDir("", config.network) / "era1"

proc ereOutputDir*(config: HistoryExportConf): string =
  case config.cmd
  of HistoryExportCmd.exportEre:
    if config.ereOutputDirFlag.isSome:
      string config.ereOutputDirFlag.get()
    else:
      config.elDataDirPath() / "ere"
  of HistoryExportCmd.exportEreFromEra1:
    if config.ereOutputDirFlagEra1.isSome:
      string config.ereOutputDirFlagEra1.get()
    else:
      parentDir(config.era1DirPath()) / "ere"
  else:
    raiseAssert "ereOutputDir called for wrong command"

const supportedNetworks* =
  [("mainnet", MainNet), ("sepolia", SepoliaNet), ("hoodi", HoodiNet)]

func parseNetworkId*(networkName: string): Result[NetworkId, string] =
  let networkLower = networkName.toLowerAscii()
  for (name, id) in supportedNetworks:
    if name == networkLower:
      return ok(id)
  err("Unsupported network: " & networkName)

func networkId*(config: HistoryExportConf): NetworkId =
  parseNetworkId(config.network).valueOr:
    raiseAssert error

const
  NimbusCopyright* =
    "Copyright (c) 2026-" & compileYear & " Status Research & Development GmbH"
  ExporterName = "nimbus_history_exporter"
  ClientVersion* = &"{ExporterName}/{FullVersionStr}/{CpuInfo}"

func mergeBlockNumber*(networkId: NetworkId): BlockNumber =
  let cfg = chainConfigForNetwork(networkId)
  if cfg.posBlock.isSome:
    cfg.posBlock.value()
  elif cfg.mergeNetsplitBlock.isSome:
    cfg.mergeNetsplitBlock.value()
  else:
    BlockNumber(0)

proc checkConfig*(cfg: HistoryExportConf) =
  let networkLower = cfg.network.toLowerAscii()
  for (name, _) in supportedNetworks:
    if name == networkLower:
      return
  fatal "Unsupported network", network = cfg.network
  quit QuitFailure
