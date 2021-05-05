# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

const
  # debugging flag, dump macro info when asked for
  noisy {.intdefine.}: int = 0
  # isNoisy {.used.} = noisy > 0
  isChatty {.used.} = noisy > 1

import
  macros

macro relayAs*(signal, relayed: untyped;
               enabled: static[bool]; code: untyped): untyped =
  ## If the argument `enabled` is set `true` at compile time, an exception
  ## sentinel around `code` is provided in order to forward the argument
  ## `signal` to argument `relayed` when executing `code`.
  ##
  ## Otherwise, the `code` is provided as-is.
  if not enabled:
    result = quote do: `code`
  else:
    var sigPfx = strVal(signal) & "("
    result = quote do:
      try:
        `code`
      except `signal` as e:
        let sigMsg = `sigPfx` & $e.name & "): " & e.msg
        raise newException(`relayed`, sigMsg)

  when isChatty:
    echo ">>> ", enabled, " >> ", result.repr


macro relayAsExcept*(signal, relayed, asIs: untyped;
                     enabled: static[bool]; code: untyped): untyped =
  ## Like `relayTo()` with an additional exception parameter `asIs`. The
  ## exception `asIs` is checked and forwarded as-is before checking `signal`.
  if not enabled:
    result = quote do: `code`
  else:
    var
      sigPfx = strVal(signal) & "("
      xclPfx = strVal(asIs) & "("
    result = quote do:
      try:
        `code`
      except `asIs` as e:
        let xMsg = `xclPfx` & $e.name & "): " & e.msg
        raise newException(`asis`, xMsg)
      except `signal` as e:
        let xMsg = `sigPfx` & $e.name & "): " & e.msg
        raise newException(`relayed`, xMsg)

  when isChatty:
    echo ">>> ", enabled, " >> ", result.repr

# End
