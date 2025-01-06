# nimbus_unified
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[os, atomics, tables], beacon_chain/nimbus_binary_common

## Exceptions
type NimbusTasksError* = object of CatchableError

## Configuration
## TODO: implement a json (or other format like yaml) config reader for config reading (file config scenarios)
##  1) implement a command line reader to read arguments
##  2) good option to adhere to other projects conventions and use the in place support to read and load
type NimbusConfig* = object
  configTable: Table[string, string]

## Nimbus workers arguments (thread arguments)
type TaskParameters* = object
  name*: string
  configs*: string
  beaconNodeConfigs*: BeaconNodeConf

## Task shutdown flag
##
## The behaviour required: this thread needs to atomically change the flag value when
##  a shutdown is required or when detects a stopped thread.
##
## Given the behaviour wanted, atomic operations are sufficient without barriers or fences. Compilers
##  may reorder instructions, but given that the order is not important, this does not affect
##  the semantic wanted: If instructions are reordered, the worker will fail to read on the current iteration
##  but will read it correctly on the next iteration ( this thread is the only on which changes the flag behaviour,
##  and will always change it to true)
##
## With this we avoid the overhead of locks
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