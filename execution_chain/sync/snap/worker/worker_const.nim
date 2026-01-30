# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronos, stint]

type
  SyncState* = enum
    idle = 0

  ErrorType* = enum
    ## For `FetchError` return code object/tuple
    EGeneric = 0                   ## Not further specified error
    ESyncerTermination             ## Syncer was stopped
    EMissingEthContext             ## Cannot retrieve `eth` peer descriptor
    EAlreadyTriedAndFailed         ## The same action failed before
    EPeerDisconnected              ## Exception
    ECatchableError                ## Exception
    ECancelledError                ## Exception

const
  snapAsmFolder* = "snap"
    ## Folder for assembly database (different from aristo `ecdb` folder)

  twoHundredYears* = chronos.days(365 * 200 + 48)
    ## Large Duration constant considered sort of infinite.

  metricsUpdateInterval* = chronos.seconds(10)
    ## Wait at least this time before next update

  daemonWaitInterval* = chronos.seconds(10)
    ## Some waiting time at the end of the daemon task which always lingers
    ## in the background.

  noPeersLogWaitInterval* = chronos.seconds(50)
    ## Control missing peers messages issued from time to time (if any.)

  syncUpdateLogWaitInterval* = chronos.seconds(30)
    ## Control log chatter for update messages

  workerIdleWaitInterval* = chronos.seconds(1)
  workerIdleLongWaitInterval* = chronos.seconds(5)
    ## Sleep some time in multi-mode (i.e. concurrently running peers) if
    ## there is nothing else to do
  asyncThreadSwitchTimeSlot* = chronos.nanoseconds(1)
    ## Nano-sleep to allows pseudo/async thread switch

  asyncThreadSwitchGap* = chronos.milliseconds(300)
    ## Controls nano-sleep tart switch density when using this in a loop (e.g.
    ## for processing lists.) The constant requires a minimum time gap when
    ## invoking a nano-sleep utility.

  # ----------------------

  unprocAccountsRangeMax* = (1.u256 shl 251) # 64 different intervals max
    ## Soft bytes limit to request accounts


  stateDbCapacity* = 4
    ## Maximal numbers of simultanous incomplete states

  stateDbBlockHeightWindow* = 128
    ## Block numbers on the database may have this distance, at most. The
    ## least entries will be deleted for moving the widow forward.

  # -----------

  fetchHeadersRlpxTimeout* = chronos.seconds(30)
    ## Timeout cap for the `RLPX` handler when fetching header. This value


  fetchAccountSnapTimeout* = chronos.seconds(120)
    ## Timeout cap for the `RLPX` handler when fetching accounts.

  nFetchAccountSnapErrThreshold* = 4
    ## Maximum account fetch errors before zombification.

  fetchAccountSnapBytesLimit* = 50 * 1024
    ## Soft bytes limit to request accounts

  # -----------

  nProcAccountErrThreshold* = 4
    ## Similar to `nFetchAccountSnapErrThreshold` but for the later part
    ## when errors occur while cached data packets are processed.


# End
