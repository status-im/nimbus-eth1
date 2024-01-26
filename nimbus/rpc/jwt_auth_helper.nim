# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  json_serialization

type
  JwtHeader* = object ##\
    ## Template used for JSON unmarshalling
    typ*, alg*: string

  JwtIatPayload* = object ##\
    ## Template used for JSON unmarshalling
    iat*: uint64

# This file separated from jwt_auth.nim
# is to prevent generic resolution clash between
# json_serialization and base64

{.push gcsafe, raises: [].}

func decodeJwtHeader*(jsonBytes: string): JwtHeader
        {.gcsafe, raises: [SerializationError].} =
  Json.decode(jsonBytes, JwtHeader)

func decodeJwtIatPayload*(jsonBytes: string): JwtIatPayload
        {.gcsafe, raises: [SerializationError].} =
  Json.decode(jsonBytes, JwtIatPayload)

{.pop.}
