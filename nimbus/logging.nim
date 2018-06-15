# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strformat, terminal

# TODO replace by nim-chronicles

type
  Logger* = object
    name*: string

const DEBUG* = defined(nimbusdebug)

# Note: to make logging costless:
#  - DEBUG should be a const and dispatch should use `when` for compile-time specialization
#  - Passing a string to a proc, even a const string and inline proc, might trigger a heap allocation
#    use a template instead.

template log*(l: Logger, msg: string, color: ForegroundColor = fgBlack) =
  when DEBUG:
    styledWriteLine(stdout, color, &"#{l.name}: {msg}", resetStyle)

template debug*(l: Logger, msg: string) =
  when DEBUG:
    l.log(msg)

template trace*(l: Logger, msg: string) =
  when DEBUG:
    l.log(msg, fgBlue)

proc getLogger*(name: string): Logger =
  result = Logger(name: name)

# proc disableLogging* =
#   DEBUG = false

# proc enableLogging* =
#   DEBUG = true
