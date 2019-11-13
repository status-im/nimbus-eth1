# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat,
  errors, eth/common

proc validateGte*(value: Int256 | int, minimum: int, title: string = "Value") =
  if value.i256 < minimum.i256:
    raise newException(ValidationError,
      &"{title} {value} is not greater than or equal to {minimum}")

proc validateGt*(value: Int256 | int, minimum: int, title: string = "Value") =
  if value.i256 <= minimum.i256:
    raise newException(ValidationError,
      &"{title} {value} is not greater than {minimum}")

proc validateLength*[T](values: seq[T], size: int) =
  if values.len != size:
    raise newException(ValidationError,
      &"seq expected {size} len, got {values.len}")

proc validateLte*(value: UInt256 | int, maximum: int, title: string = "Value") =
  if value.u256 > maximum.u256:
    raise newException(ValidationError,
      &"{title} {value} is not less or equal to {maximum}")

proc validateLt*(value: UInt256 | int, maximum: int, title: string = "Value") =
  if value.u256 >= maximum.u256:
    raise newException(ValidationError,
      &"{title} {value} is not less than {maximum}")

proc validateStackItem*(value: string) =
  if value.len > 32:
    raise newException(ValidationError,
      &"Invalid stack item: expected 32 bytes, got {value.len}: value is {value}")

proc validateStackItem*(value: openarray[byte]) =
  if value.len > 32:
    raise newException(ValidationError,
      &"Invalid stack item: expected 32 bytes, got {value.len}: value is {value}")
