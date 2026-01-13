# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common/block_access_lists,
  web3/[eth_api_types, conversions],
  ../beacon/web3_eth_conv

export
  eth_api_types,
  web3_eth_conv

type
  FilterLog* = eth_api_types.LogObject

  # BlockTag instead of BlockId:
  # prevent type clash with eth2 BlockId in portal/verified_proxy
  BlockTag* = eth_api_types.RtBlockIdentifier

# Block access list json serialization
AccountChanges.useDefaultSerializationIn EthJson
SlotChanges.useDefaultSerializationIn EthJson
StorageChange.useDefaultSerializationIn EthJson
BalanceChange.useDefaultSerializationIn EthJson
NonceChange.useDefaultSerializationIn EthJson
CodeChange.useDefaultSerializationIn EthJson
