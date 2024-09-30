# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common,
  stew/arrayops,
  stew/endians2,
  results,
  ../constants

# -----------------------------------------------------------------------------
# Private helpers
# -----------------------------------------------------------------------------

# UnpackIntoDeposit unpacks a serialized DepositEvent.
func unpackIntoDeposit(data: openArray[byte]): Result[Request, string] =
  if data.len != 576:
    return err("deposit wrong length: want 576, have " & $data.len)

  # The ABI encodes the position of dynamic elements first. Since there
  # are 5 elements, skip over the positional data. The first 32 bytes of
  # dynamic elements also encode their actual length. Skip over that value too.
  const
    b = 32*5 + 32
    c = b + 48 + 16 + 32
    d = c + 32 + 32
    e = d + 8 + 24 + 32
    f = e + 96 + 32

  let res = Request(
    requestType: DepositRequestType,
    deposit: DepositRequest(
      # PublicKey is the first element. ABI encoding pads values to 32 bytes,
      # so despite BLS public keys being length 48, the value length
      # here is 64. Then skip over the next length value.
      pubkey: Bytes48.copyFrom(data, b),

      # WithdrawalCredentials is 32 bytes. Read that value then skip over next
      # length.
      withdrawalCredentials: Bytes32.copyFrom(data, c),

      # Amount is 8 bytes, but it is padded to 32. Skip over it and the next
      # length.
      amount: uint64.fromBytesLE(data.toOpenArray(d, d+7)),

      # Signature is 96 bytes. Skip over it and the next length.
      signature: Bytes96.copyFrom(data, e),

      # Amount is 8 bytes.
      index: uint64.fromBytesLE(data.toOpenArray(f, f+7)),
    )
  )
  ok(res)

# -----------------------------------------------------------------------------
# Public functions
# -----------------------------------------------------------------------------

func parseDepositLogs*(logs: openArray[Log]): Result[seq[Request], string] =
  var res: seq[Request]
  for log in logs:
    if log.address == DEPOSIT_CONTRACT_ADDRESS:
      res.add ?unpackIntoDeposit(log.data)
  ok(res)
