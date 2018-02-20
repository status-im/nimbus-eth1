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

proc pad(value: string, size: int, with: string, left: bool): string =
  let padAmount = size - value.len
  if padAmount > 0:
    let fill = repeat(with, padAmount)
    if left:
      result = &"{fill}{value}"
    else:
      result = &"{value}{fill}"
  else:
    result = value

proc pad[T](value: seq[T], size: int, element: T, left: bool): seq[T] =
  let padAmount = size - value.len
  if padAmount > 0:
    let fill = repeat(element, padAmount)
    if left:
      result = fill.concat(value)
    else:
      result = value.concat(fill)
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


template padLeft*(value: string, size: int, with: string): string =
  pad(value, size, with, true)

template padRight*(value: string, size: int, with: string): string =
  pad(value, size, with, false)

template zpadRight*(value: string, size: int): string =
  padRight(value, size, with="\x00")

template zpadLeft*(value: string, size: int): string =
  padLeft(value, size, with="\x00")

template pad32*(value: string): string =
  zpadLeft(value, size=32)

template pad32r*(value: string): string =
  zpadRight(value, size=32)


proc lStrip*(value: cstring, c: char): cstring =
  var z = 0
  while z < value.len and value[z] == c:
    z += 1
  if z == 0:
    result = value
  elif z == value.len:
    result = cstring""
  else:
    result = cstring(($value)[z..^1])

proc rStrip*(value: cstring, c: char): cstring =
  var z = value.len - 1
  while z >= 0 and value[z] == c:
    z -= 1
  if z == value.len - 1:
    result = value
  elif z == -1:
    result = cstring""
  else:
    result = cstring(($value)[0..z])  

proc strip*(value: cstring, c: char): cstring =
  result = value.lStrip(c).rStrip(c)

proc lStrip*(value: string, c: char): string =
  value.strip(chars={c}, trailing=false)

proc rStip*(value: string, c: char): string =
  value.strip(chars={c}, leading=false)


template padLeft*[T](value: seq[T], size: int, element: T): seq[T] =
  pad(value, size, element, true)

template padRight*[T](value: seq[T], size: int, element: T): seq[T] =
  pad(value, size, element, false)

template zpadRight*[T](value: seq[T], size: int): seq[T] =
  padRight(value, size, 0.byte)

template zpadLeft*[T](value: seq[T], size: int): seq[T] =
  padLeft(value, size, 0.byte)

template pad32*[T](value: seq[T]): seq[T] =
  zpadLeft(value, 32)

template pad32r*[T](value: seq[T]): seq[T] =
  zpadRight(value, 32)

proc lStrip*[T](value: seq[T], element: T): seq[T] =
  var z = 0
  while z < value.len and value[z] == element:
    z += 1
  if z == 0:
    result = value
  elif z == value.len:
    result = @[]
  else:
    result = value[z..^1]

proc rStrip*[T](value: seq[T], element: T): seq[T] =
  var z = value.len - 1
  while z >= 0 and value[z] == element:
    z -= 1
  if z == value.len - 1:
    result = value
  elif z == -1:
    result = @[]
  else:
    result = value[0..z]

