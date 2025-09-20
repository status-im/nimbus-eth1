# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Wrapper to expose `run()` from `nimbus_execution_client.nim` without
## marking is exportable.

include # (!)
  ../../../execution_chain/nimbus_execution_client

proc runNimbusExeClient*(conf: NimbusConf; cfgCB: BeaconSyncConfigHook) =
  ## Wrapper, make it public for debugging
  ProcessState.setupStopHandlers()

  # Set up logging before everything else
  setupLogging(conf.logLevel, conf.logStdout, none(OutFile))
  setupFileLimits()

  # TODO provide option for fixing / ignoring permission errors
  if not checkAndCreateDataDir(conf.dataDir):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  let nimbus = NimbusNode(
    ctx:           newEthContext(),
    beaconSyncRef: BeaconSyncRef.init cfgCB)

  nimbus.run(conf)

# End
