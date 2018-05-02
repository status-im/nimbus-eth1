# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

type
  ServiceState* = enum
    Stopped,
    Starting,
    Running,
    Pausing,
    Paused,
    Resuming,
    Failure

  ServiceStatus* = enum
    Success,
    Error

  ServiceFlags* = enum
    Configured

  NetworkService* = object of RootObj
    id*: string
    flags*: set[ServiceFlags]
    state*: ServiceState
    error*: string

template checkState*(s: var NetworkService,
                     need: set[ServiceState]) =
  if s.state notin need:
    s.error = "Service [" & s.id & "] state is {" & $s.state & "} but " &
              $need & " required!"
    return(Error)

template cleanError*(s: var NetworkService) =
  s.error.setLen(0)

template checkFlags*(s: var NetworkService,
                     need: set[ServiceFlags],
                     msg: string) =
  if s.flags * need != need:
    s.error = "Service [" & s.id & "] is " & msg
    return(Error)

template setFailure*(s: var NetworkService, msg: string) =
  s.state = Failure
  s.error = "Service [" & s.id & "] returns error: " & msg

template errorMessage*(s: NetworkService): string =
  s.error