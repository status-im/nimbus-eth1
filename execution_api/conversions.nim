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
PayloadStatus.useDefaultReaderIn EthJson
ForkchoiceUpdatedResponse.useDefaultSerializationIn EthJson

proc writeValue*(w: var JsonWriter[EthJson], v: PayloadStatus)
      {.gcsafe, raises: [IOError].} =
  # `witness` (engine_newPayloadWithWitness*) and `inclusionListSatisfied`
  # are extensions to PayloadStatusV1. They must be omitted, not written as
  # `null`, when unset.
  mixin writeValue
  w.beginObject()
  for k, val in fieldPairs(v):
    when k in ["witness", "inclusionListSatisfied"]:
      if val.isSome:
        w.writeMember(k, val)
    else:
      w.writeMember(k, val)
  w.endObject()

{.pop.}
