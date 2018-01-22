import strformat, strutils

proc repeat*(b: cstring, count: int): cstring =
  # TODO
  result = cstring(repeat($b, count))

proc pad(value: cstring, size: int, with: cstring, left: bool): cstring =
  let padAmount = size - value.len
  if padAmount > 0:
    let fill = repeat(($with), padAmount)
    if left:
      result = cstring(&"{fill}{value}")
    else:
      result = cstring(&"{value}{fill}")
  else:
    result = value


template padLeft*(value: cstring, size: int, with: cstring): cstring =
  pad(value, size, with, true)

template padRight*(value: cstring, size: int, with: cstring): cstring =
  pad(value, size, with, false)

template zpadRight*(value: cstring, size: int): cstring =
  padRight(value, size, with=cstring"\x00")

template zpadLeft*(value: cstring, size: int): cstring =
  padLeft(value, size, with=cstring"\x00")

template pad32*(value: cstring): cstring =
  zpadLeft(value, size=32)

template pad32r*(value: cstring): cstring =
  zpadRight(value, size=32)

