# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import config
import p2p/service, p2p/disc4service

when isMainModule:
  var message: string
  if processArguments(message) != ConfigStatus.Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message

  var disc4: Discovery4Service
  if disc4.init() != ServiceStatus.Success:
    quit(QuitFailure)
  if disc4.configure() != ServiceStatus.Success:
    echo disc4.errorMessage()
    quit(QuitFailure)
  if disc4.start() != ServiceStatus.Success:
    echo disc4.errorMessage()
    quit(QuitFailure)
