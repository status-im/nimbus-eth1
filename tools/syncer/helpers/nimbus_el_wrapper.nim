# This file may not be copied, modified, or distributed except according to
# those terms.

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
