# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/lists, ../engine/types, chronos


type
  Task* = ref object
    status*: int
    name*: string
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

  CallBackProc* =
    proc(ctx: ptr Context, status: int, res: cstring) {.cdecl, gcsafe, raises: [].}


