# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[atomics, tables],
  chronicles


## log
logScope:
  topics = "Service manager"

## Exceptions
type NimbusServiceError* = object of CatchableError

## Constants
const
  cNimbusServiceTimeoutMs* = 3000
  cThreadTimeAck* = 10

# configuration read by threads
var isConfigRead*: Atomic[bool]
isConfigRead.store(false)

## Nimbus service arguments
type
  NimbusConfigTable* = Table[string, string]

  ConfigKind* = enum
    Execution
    Consensus

  LayerConfig* = object
    case kind*: ConfigKind
    of Consensus:
      consensusOptions*: NimbusConfigTable
    of Execution:
      executionOptions*: NimbusConfigTable

  NimbusService* = ref object
    name*: string
    layerConfig*: LayerConfig
    serviceHandler*: Thread[ptr Channel[pointer]]
    serviceFunc*: proc(ch: ptr Channel[pointer]) {.thread.}

  Nimbus* = ref object
    serviceList*: seq[NimbusService]
