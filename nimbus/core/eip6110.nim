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
  eth/common/receipts,
  stew/assign2,
  stew/arrayops,
  results,
  ../constants

# -----------------------------------------------------------------------------
# Private helpers
# -----------------------------------------------------------------------------

const
  depositRequestSize = 192

type
  DepositRequest = array[depositRequestSize, byte]

# UnpackIntoDeposit unpacks a serialized DepositEvent.
func depositLogToRequest(data: openArray[byte]): DepositRequest =
  # The ABI encodes the position of dynamic elements first. Since there
  # are 5 elements, skip over the positional data. The first 32 bytes of
  # dynamic elements also encode their actual length. Skip over that value too.
  const
    b = 32*5 + 32
    c = b + 48 + 16 + 32
    d = c + 32 + 32
    e = d + 8 + 24 + 32
    f = e + 96 + 32
    pubkeyOffset         = 0
    withdrawalCredOffset = pubkeyOffset + 48
    amountOffset         = withdrawalCredOffset + 32
    signatureOffset      = amountOffset + 8
    indexOffset          = signatureOffset + 96

  template copyFrom(tgtOffset, srcOffset, len) =
    assign(result.toOpenArray(tgtOffset, tgtOffset+len-1),
      data.toOpenArray(srcOffset, srcOffset+len-1))

  # PublicKey is the first element. ABI encoding pads values to 32 bytes,
  # so despite BLS public keys being length 48, the value length
  # here is 64. Then skip over the next length value.
  copyFrom(pubkeyOffset, b, 48)

  # WithdrawalCredentials is 32 bytes. Read that value then skip over next
  # length.
  copyFrom(withdrawalCredOffset, c, 32)

  # Amount is 8 bytes, but it is padded to 32. Skip over it and the next
  # length.
  copyFrom(amountOffset, d, 8)

  # Signature is 96 bytes. Skip over it and the next length.
  copyFrom(signatureOffset, e, 96)

  # Amount is 8 bytes.
  copyFrom(indexOffset, f, 8)

# -----------------------------------------------------------------------------
# Public functions
# -----------------------------------------------------------------------------

func parseDepositLogs*(logs: openArray[Log]): Result[seq[byte], string] =
  var res = newSeq[byte](logs.len*depositRequestSize)
  for i, log in logs:
    if log.address == DEPOSIT_CONTRACT_ADDRESS:
      if log.data.len != 576:
        return err("deposit wrong length: want 576, have " & $log.data.len)
    let offset = i*depositRequestSize
    assign(res.toOpenArray(offset, offset+depositRequestSize-1),
      depositLogToRequest(log.data))

  ok(move(res))
