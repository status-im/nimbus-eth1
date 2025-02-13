# Nimbus
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
  ../../execution_chain/nimbus_desc

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
      consensusConfig*: seq[string]
    of Execution:
      executionConfig*: seq[string]

  NimbusService* = ref object
    name*: string
    layerConfig*: LayerConfig
    serviceHandler*: Thread[ptr Channel[pointer]]
    serviceChannel: ptr Channel[pointer]

  Nimbus* = ref object
    serviceList*: seq[NimbusService]

#replace with cond var
## Service shutdown
var isShutDownRequired*: Atomic[bool]
isShutDownRequired.store(false)

# filesystem specs
proc defaultDataDir*(): string =
  let dataDir =
    when defined(windows):
      "AppData" / "Roaming" / "Nimbus"
    elif defined(macosx):
      "Library" / "Application Support" / "Nimbus"
    else:
      ".cache" / "Nimbus"

  getHomeDir() / dataDir
