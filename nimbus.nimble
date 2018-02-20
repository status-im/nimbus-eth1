mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 0.17.0",
         "https://github.com/status-im/nim-keccak-tiny.git >= 0.1.0",
         "https://github.com/status-im/nim-rlp.git >= 1.0.0",
         "https://github.com/status-im/nim-ttmath >= 0.5.0"



