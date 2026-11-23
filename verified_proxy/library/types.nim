# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import chronos, ../engine/types

type
  Context* = object
    config*: string
    stop*: bool
    pendingCalls*: int
    engine*: RpcVerificationEngine
    opEngine*: RpcVerificationEngine
    frontend*: ExecutionApiFrontend
    opFrontend*: ExecutionApiFrontend

  CallBackProc* = proc(ctx: ptr Context, status: cint, res: cstring, userData: pointer) {.
    cdecl, gcsafe, raises: []
  .}

  TransportDeliveryCallback* =
    proc(status: cint, res: cstring, userData: pointer) {.cdecl, gcsafe, raises: [].}

  ExecutionTransportProc* = proc(
    ctx: ptr Context, cb: TransportDeliveryCallback, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  BeaconTransportProc* = proc(
    ctx: ptr Context, cb: TransportDeliveryCallback, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  StorageDeliveryCallback* = proc(
    status: cint, data: ptr UncheckedArray[byte], len: cint, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  StorageGetProc* = proc(
    ctx: ptr Context, key: cstring, cb: StorageDeliveryCallback, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  StoragePutProc* = proc(
    ctx: ptr Context,
    key: cstring,
    data: ptr UncheckedArray[byte],
    len: cint,
    cb: StorageDeliveryCallback,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  StorageContext* = ref object
    fut*: Future[(cint, seq[byte])]

  TransportExecutionContext* = ref object
    url*: string
    name*: string
    params*: string
    fut*: Future[string]

  TransportBeaconContext* = ref object
    url*: string
    endpoint*: string
    params*: string
    fut*: Future[string]

const RET_SUCCESS*: cint = 0
const RET_ERROR*: cint = -1
const RET_CANCELLED*: cint = -2
const RET_DESER_ERROR*: cint = -3
const RET_NOT_FOUND*: cint = -4
