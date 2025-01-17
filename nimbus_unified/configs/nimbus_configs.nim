# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, atomics],
  #eth2
  beacon_chain/nimbus_binary_common,
  #eth1
  ../../nimbus/nimbus_desc

## Exceptions
type NimbusServicesListError* = object of CatchableError

## Constants
## TODO: evaluate the proposed timeouts
const cNimbusMaxServices* = 5
const cNimbusServiceTimeoutMs* = 5000

## log
logScope:
  topics = "Service manager"

## Nimbus workers arguments (thread arguments)
type
  ConfigKind* = enum
    Execution
    Consensus

  LayerConfig* = object
    case kind*: ConfigKind
    of Consensus:
      consensusConfig*: BeaconNodeConf
    of Execution:
      executionConfig*: NimbusConf

  ServiceParameters* = object
    name*: string
    layerConfig*: LayerConfig

## Service and associated service information
type NimbusService* = ref object #experimentar tipos com ref
  name*: string
  timeoutMs*: uint32
  threadHandler*: Thread[ServiceParameters]

## Service manager
type NimbusServicesList* = ref object
  serviceList*: array[cNimbusMaxServices, Option[NimbusService]]

## Service shutdown
var isShutDownRequired*: Atomic[bool]
isShutDownRequired.store(false)

# TODO: move this into config.nim file once we have the file in place
proc defaultDataDir*(): string =
  let dataDir =
    when defined(windows):
      "AppData" / "Roaming" / "Nimbus_unified"
    elif defined(macosx):
      "Library" / "Application Support" / "Nimbus_unified"
    else:
      ".cache" / "nimbus_unified"

  getHomeDir() / dataDir
