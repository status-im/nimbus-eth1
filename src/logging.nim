import strformat

type
  Logger* = object
    name*: string

const DEBUG = true

proc log*(l: Logger, msg: string) =
  echo fmt"#{l.name}: {msg}"

proc debug*(l: Logger, msg: string) =
  if DEBUG:
    l.log(msg)

proc trace*(l: Logger, msg: string) =
  l.log(msg)

proc getLogger*(name: string): Logger =
  result = Logger(name: name)
