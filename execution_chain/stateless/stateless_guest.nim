# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import stew/[byteutils, endians2], ./stateless_types

export stateless_types

# https://github.com/ethereum/execution-specs/blob/f03c2e0af2df95cd2eed029ba4ea7140acd028c7/src/ethereum/forks/amsterdam/stateless_guest.py#L36
func deserialize_stateless_input*(
    data: openArray[byte]
): Result[StatelessInput, string] =
  if data.len < STATELESS_INPUT_SCHEMA_ID_SIZE:
    return err("Stateless input is missing schema id")
  let schema_id = uint16.fromBytesBE(data.toOpenArray(0, 1))
  if schema_id != STATELESS_INPUT_SCHEMA_ID:
    return
      err("Unsupported stateless input schema id: " & schema_id.toBytesBE().to0xHex())
  try:
    ok(
      SSZ.decode(
        data.toOpenArray(STATELESS_INPUT_SCHEMA_ID_SIZE, data.high), StatelessInput
      )
    )
  except SerializationError as e:
    err("Failed to deserialize StatelessInput: " & e.msg)
