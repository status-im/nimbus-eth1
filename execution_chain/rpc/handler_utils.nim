# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  json_rpc/rpcserver,
  results

proc invalidParams*(msg: string) {.raises: [ref ApplicationError].} =
  raise (ref ApplicationError)(code: -32602, msg: msg)

template getOrInvalidParam*[T](res: Result[Opt[T], string], onMissing: untyped): T =
  let resolved = res
  if resolved.isErr:
    let errMsg = resolved.error
    invalidParams(errMsg)
  let found = resolved.get()
  if found.isNone:
    onMissing
  found.get()

template getOrRaise*[T](res: Result[Opt[T], string], msg: string): T =
  getOrInvalidParam(res):
    raise newException(ValueError, msg)
