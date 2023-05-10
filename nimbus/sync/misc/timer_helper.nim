# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  chronos

{.push raises: [].}

# Use `safeSetTimer` consistently, with a `ref T` argument if including one.
type
  SafeCallbackFunc*[T] = proc (objectRef: ref T) {.gcsafe, raises: [].}
  SafeCallbackFuncVoid* = proc () {.gcsafe, raises: [].}

proc safeSetTimer*[T](at: Moment, cb: SafeCallbackFunc[T],
                      objectRef: ref T = nil): TimerCallback =
  ## Like `setTimer` but takes a typed `ref T` argument, which is passed to the
  ## callback function correctly typed.  Stores the `ref` in a closure to avoid
  ## garbage collection memory corruption issues that occur when the `setTimer`
  ## pointer argument is used.
  proc chronosTimerSafeCb(udata: pointer) = cb(objectRef)
  return setTimer(at, chronosTimerSafeCb)

proc safeSetTimer*[T](at: Moment, cb: SafeCallbackFuncVoid): TimerCallback =
  ## Like `setTimer` but takes no pointer argument.  The callback function
  ## takes no arguments.
  proc chronosTimerSafeCb(udata: pointer) = cb()
  return setTimer(at, chronosTimerSafeCb)

proc setTimer*(at: Moment, cb: CallbackFunc, udata: pointer): TimerCallback
  {.error: "Do not use setTimer with a `pointer` type argument".}
  ## `setTimer` with a non-nil pointer argument is dangerous because
  ## the pointed-to object is often freed or garbage collected before the
  ## timer callback runs.  Call `setTimer` with a `ref` argument instead.

proc setTimer*(at: Moment, cb: CallbackFunc): TimerCallback =
  chronos.setTimer(at, cb, nil)

# End
