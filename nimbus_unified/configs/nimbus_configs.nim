# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[atomics, tables], beacon_chain/nimbus_binary_common

## Exceptions
type NimbusTasksError* = object of CatchableError

## Configuration
## TODO: implement a json (or other format like yaml) config reader for config reading (file config scenarios)
## TODO: implement a command line reader to read arguments
type NimbusConfig* = object
  configTable: Table[string, string]

## Nimbus workers arguments (thread arguments)
type TaskParameters* = object
  name*: string
  configs*: string
  beaconNodeConfigs*: BeaconNodeConf
    # TODO: replace this with the extracted configs from NimbusConfig needed by the worker

## Task shutdown flag
## The behaviour required: this thread needs to atomically change the flag value when
##  a shutdown is required or when detects a stopped thread.
## Given the behaviour wanted, atomic operations are sufficient without barriers or fences. Compilers
##  may reorder instructions, but given that the order is not important, this does not affect
##  the semantic wanted: If instructions are reordered, the worker will fail to read on the current iteration
##  but will read it correctly on the next iteration ( this thread is the only on which changes the flag behaviour,
##  and will always change it to true)
var isShutDownRequired*: Atomic[bool]
isShutDownRequired.store(false)
