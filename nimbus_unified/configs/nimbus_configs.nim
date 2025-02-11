# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, atomics],
  chronicles,
  options,
  #eth2-configs
  beacon_chain/nimbus_binary_common,
  #eth1-configs
  ../../nimbus/nimbus_desc

export BeaconNodeConf, NimbusConf

## Exceptions
type NimbusServiceError* = object of CatchableError

## Constants
## TODO: evaluate the proposed timeouts
const cNimbusMaxServices* = 2
const cNimbusServiceTimeoutMs* = 3000

## log
logScope:
  topics = "Service manager"

## Nimbus service arguments
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

  NimbusService* = ref object
    name*: string
    timeoutMs*: uint32
    serviceHandler*: Thread[ServiceParameters]

  Nimbus* = ref object
    serviceList*: array[cNimbusMaxServices, Option[NimbusService]]

## Service shutdown
var isShutDownRequired*: Atomic[bool]
isShutDownRequired.store(false)

# filesystem specs
proc defaultDataDir*(): string =
  let dataDir =
    when defined(windows):
      "AppData" / "Roaming" / "Nimbus_unified"
    elif defined(macosx):
      "Library" / "Application Support" / "Nimbus_unified"
    else:
      ".cache" / "nimbus_unified"

  getHomeDir() / dataDir
