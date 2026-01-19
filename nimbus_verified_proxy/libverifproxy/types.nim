# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/lists, ../engine/types, chronos

type
  Task* = ref object
    status*: cint
    userData*: pointer
    response*: string
    finished*: bool
    cb*: CallBackProc
    fut*: FutureBase

  Context* = object
    config*: string
    tasks*: SinglyLinkedList[Task]
    taskLen*: int
    stop*: bool
    frontend*: EthApiFrontend

  CallBackProc* = proc(ctx: ptr Context, status: cint, res: cstring, userData: pointer) {.
    cdecl, gcsafe, raises: []
  .}

const RET_SUCCESS*: cint = 0 # when the call to eth api frontend is successful
const RET_ERROR*: cint = -1 # when the call to eth api frontend failed with an error
const RET_CANCELLED*: cint = -2 # when the call to the eth api frontend was cancelled
const RET_DESER_ERROR*: cint = -3
  # when an error occured while deserializing arguments from C to Nim
