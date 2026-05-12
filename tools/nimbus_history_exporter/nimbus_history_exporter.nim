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
  chronicles,
  beacon_chain/nimbus_binary_common,
  ../../execution_chain/compile_info,
  ./nimbus_history_exporter_conf,
  ./ere_export

proc main() =
  let config = HistoryExportConf.loadWithBanners(
    ClientVersion, NimbusCopyright, [], false
  ).valueOr:
    writePanicLine error
    quit QuitFailure

  setupLogging(config.logLevel, config.logFormat)

  checkConfig(config)

  info "Launching nimbus_history_exporter", version = FullVersionStr

  case config.cmd
  of HistoryExportCmd.exportEre:
    exportEre(config)
  of HistoryExportCmd.verifyEre:
    verifyEreDir(config, config.ereVerifyDir.string)
  of HistoryExportCmd.verifyEreFile:
    verifyEreFile(config, config.ereFile.string).isOkOr:
      fatal "Verification of ere file failed", error = error
      quit(QuitFailure)

when isMainModule:
  main()
