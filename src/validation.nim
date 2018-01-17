

import
  strformat,
  errors, constants

proc validateCanonicalAddress*(value: cstring, title: string = "Value") =
  if len(value) != 20:
    raise newException(ValidationError,
      fmt"{title} {value} is not a valid canonical address")




proc validateGte*(value: Int256, minimum: int, title: string = "Value") =
  if value <= minimum.Int256:
    raise newException(ValidationError,
      fmt"{title} {value} is not greater than or equal to {minimum}")

proc validateGt*(value: Int256, minimum: int, title: string = "Value") =
  if value < minimum.Int256:
    raise newException(ValidationError,
      fmt"{title} {value} is not greater than or equal to {minimum}")

proc validateGt*(value: int, minimum: int, title: string = "Value") =
  if value < minimum:
    raise newException(ValidationError,
      fmt"{title} {value} is not greater than or equal to {minimum}")
