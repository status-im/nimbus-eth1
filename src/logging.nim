import strformat

type
  Logger* = object
    name*: string

proc log*(l: Logger, msg: string) =
  echo fmt"#{l.name}: {msg}"

proc trace*(l: Logger, msg: string) =
  echo fmt"#{l.name}: {msg}"

proc getLogger*(name: string): Logger =
  result = Logger(name: name)
