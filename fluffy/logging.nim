# Nimbus Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Note:
# Code taken from nimbus-eth2/beacon_chain/nimbus_binary_common with minor
# adjustments. The write to file logic is removed as it never was an option
# in Fluffy.

{.push raises: [].}

import
  std/[strutils, tables, terminal, typetraits],
  pkg/chronicles, pkg/chronicles/helpers, chronicles/topics_registry,
  pkg/stew/results

export results

type
  StdoutLogKind* {.pure.} = enum
    Auto = "auto"
    Colors = "colors"
    NoColors = "nocolors"
    Json = "json"
    None = "none"

# silly chronicles, colors is a compile-time property
proc stripAnsi(v: string): string =
  var
    res = newStringOfCap(v.len)
    i: int

  while i < v.len:
    let c = v[i]
    if c == '\x1b':
      var
        x = i + 1
        found = false

      while x < v.len: # look for [..m
        let c2 = v[x]
        if x == i + 1:
          if c2 != '[':
            break
        else:
          if c2 in {'0'..'9'} + {';'}:
            discard # keep looking
          elif c2 == 'm':
            i = x + 1
            found = true
            break
          else:
            break
        inc x

      if found: # skip adding c
        continue
    res.add c
    inc i

  res

proc updateLogLevel(logLevel: string) {.raises: [ValueError].} =
  # Updates log levels (without clearing old ones)
  let directives = logLevel.split(";")
  try:
    setLogLevel(parseEnum[LogLevel](directives[0].capitalizeAscii()))
  except ValueError:
    raise (ref ValueError)(msg: "Please specify one of TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL")

  if directives.len > 1:
    for topicName, settings in parseTopicDirectives(directives[1..^1]):
      if not setTopicState(topicName, settings.state, settings.logLevel):
        warn "Unrecognized logging topic", topic = topicName

proc detectTTY(stdoutKind: StdoutLogKind): StdoutLogKind =
  if stdoutKind == StdoutLogKind.Auto:
    if isatty(stdout):
      # On a TTY, let's be fancy
      StdoutLogKind.Colors
    else:
      # When there's no TTY, we output no colors because this matches what
      # released binaries were doing before auto-detection was around and
      # looks decent in systemd-captured journals.
      StdoutLogKind.NoColors
  else:
    stdoutKind

proc setupLogging*(
    logLevel: string, stdoutKind: StdoutLogKind) =
  # In the cfg file for fluffy, we create two formats: textlines and json.
  # Here, we either write those logs to an output, or not, depending on the
  # given configuration.
  # Arguably, if we don't use a format, chronicles should not create it.

  when defaultChroniclesStream.outputs.type.arity != 2:
    warn "Logging configuration options not enabled in the current build"
  else:
    # Naive approach where chronicles will form a string and we will discard
    # it, even if it could have skipped the formatting phase
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) = discard
    proc writeAndFlush(f: File, msg: LogOutputStr) =
      try:
        f.write(msg)
        f.flushFile()
      except IOError as err:
        logLoggingFailure(cstring(msg), err)

    proc stdoutFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, msg)

    proc noColorsFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, stripAnsi(msg))

    defaultChroniclesStream.outputs[1].writer = noOutput

    let tmp = detectTTY(stdoutKind)

    case tmp
    of StdoutLogKind.Auto: raiseAssert "checked in detectTTY"
    of StdoutLogKind.Colors:
      defaultChroniclesStream.outputs[0].writer = stdoutFlush
    of StdoutLogKind.NoColors:
      defaultChroniclesStream.outputs[0].writer = noColorsFlush
    of StdoutLogKind.Json:
      defaultChroniclesStream.outputs[0].writer = noOutput

      let prevWriter = defaultChroniclesStream.outputs[1].writer
      defaultChroniclesStream.outputs[1].writer =
        proc(logLevel: LogLevel, msg: LogOutputStr) =
          stdoutFlush(logLevel, msg)
          prevWriter(logLevel, msg)
    of StdoutLogKind.None:
     defaultChroniclesStream.outputs[0].writer = noOutput

  try:
    updateLogLevel(logLevel)
  except ValueError as err:
    try:
      stderr.write "Invalid value for --log-level. " & err.msg
    except IOError:
      echo "Invalid value for --log-level. " & err.msg
    quit 1
