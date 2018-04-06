# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strformat, terminal

type
  Logger* = object
    name*: string

var DEBUG* = defined(nimbusdebug)

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
