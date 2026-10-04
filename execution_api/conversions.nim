# nimbus-execution-client
# Copyright (c) 2019-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push gcsafe, raises: [].}

import
  web3/conversions,
  ./execution_types

export
  conversions,
  execution_types

ExecutionPayload.useDefaultSerializationIn EthJson
PayloadAttributes.useDefaultSerializationIn EthJson
GetPayloadResponse.useDefaultSerializationIn EthJson
ForkchoiceState.useDefaultSerializationIn EthJson
PayloadStatus.useDefaultSerializationIn EthJson
ForkchoiceUpdatedResponse.useDefaultSerializationIn EthJson

{.pop.}
