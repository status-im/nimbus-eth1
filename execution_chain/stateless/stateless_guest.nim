# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import stew/[byteutils, endians2], ./[stateless_types, stateless_execution]

export stateless_types, stateless_execution

## Stateless guest interfaces
## Spec:
## https://github.com/ethereum/execution-specs/blob/e5a8caf1b8055e4d805c7fb169edfa710914b7da/src/ethereum/forks/amsterdam/stateless_guest.py#L1

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

const FAILED_STATELESS_OUTPUT = StatelessValidationResult(
  new_payload_request_root: default(Digest),
  successful_validation: false,
  chain_config: default(StatelessChainConfig),
)

proc run_stateless_guest*(data: openArray[byte]): seq[byte] =
  let input = deserialize_stateless_input(data).valueOr:
    return SSZ.encode(FAILED_STATELESS_OUTPUT)

  SSZ.encode(verify_stateless_new_payload(input))
