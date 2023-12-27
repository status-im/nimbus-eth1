# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  web3/eth_api_types,
  ../beacon/web3_eth_conv

export
  eth_api_types,
  web3_eth_conv

type
  FilterLog* = eth_api_types.LogObject

  # BlockTag instead of BlockId:
  # prevent type clash with eth2 BlockId in fluffy/verified_proxy
  BlockTag* = eth_api_types.RtBlockIdentifier
