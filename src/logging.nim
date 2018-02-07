import strformat

type
  Logger* = object
    name*: string

var DEBUG = true

proc log*(l: Logger, msg: string) =
  if DEBUG:
    echo &"#{l.name}: {msg}"

proc debug*(l: Logger, msg: string) =
  if DEBUG:
    l.log(msg)

proc trace*(l: Logger, msg: string) =
  if DEBUG:
    l.log(msg)

proc getLogger*(name: string): Logger =
  result = Logger(name: name)

proc disableLogging* =
  DEBUG = false

proc enableLogging* =
  DEBUG = true
