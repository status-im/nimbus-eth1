import
  strformat,
  errors, constants, bigints

proc validateCanonicalAddress*(value: string, title: string = "Value") =
  # TODO
  if false: #len(value) != 20:
    raise newException(ValidationError,
      &"{title} {value} is not a valid canonical address")




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

proc validateLte*(value: Int256 | int, maximum: int, title: string = "Value") =
  if value.i256 > maximum.i256:
    raise newException(ValidationError,
      &"{title} {value} is not less or equal to {maximum}")

proc validateLt*(value: Int256 | int, maximum: int, title: string = "Value") =
  if value.i256 >= maximum.i256:
    raise newException(ValidationError,
      &"{title} {value} is not less than {maximum}")

proc validateStackItem*(value: string) =
  if value.len > 32:
    raise newException(ValidationError,
      &"Invalid stack item: expected 32 bytes, got {value.len}: value is {value}")
