# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import json_rpc/rpcserver, ../constants, ../common/common

proc setupExpRpc*(com: CommonRef, server: RpcServer) =
  # Currently no experimental endpoints

  discard
