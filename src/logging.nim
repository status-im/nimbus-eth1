import strformat, terminal

type
  Logger* = object
    name*: string

var DEBUG* = false

proc log*(l: Logger, msg: string, color: ForegroundColor = fgBlack) =
  if DEBUG:
    styledWriteLine(stdout, color, &"#{l.name}: {msg}", resetStyle)

proc debug*(l: Logger, msg: string) =
  if DEBUG:
    l.log(msg)

proc trace*(l: Logger, msg: string) =
  if DEBUG:
    l.log(msg, fgBlue)

proc getLogger*(name: string): Logger =
  result = Logger(name: name)

proc disableLogging* =
  DEBUG = false

proc enableLogging* =
  DEBUG = true
