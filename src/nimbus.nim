# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import config, asyncdispatch
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
  echo disc4.init()
  echo disc4.configure()
  echo disc4.errorMessage()
  echo disc4.start()
  echo disc4.errorMessage()
