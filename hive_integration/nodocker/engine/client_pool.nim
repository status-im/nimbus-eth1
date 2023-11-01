# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  json_rpc/rpcclient,
  ./engine_env

type
  ClientPool* = ref object
    clients: seq[EngineEnv]

proc add*(pool: ClientPool, client: EngineEnv) =
  pool.clients.add client

func first*(pool: ClientPool): EngineEnv =
  pool.clients[0]

func len*(pool: ClientPool): int =
  pool.clients.len

func `[]`*(pool: ClientPool, idx: int): EngineEnv =
  pool.clients[idx]

iterator items*(pool: ClientPool): EngineEnv =
  for x in pool.clients:
    yield x

proc remove*(pool: ClientPool, client: EngineEnv) =
  var index = -1
  for i, x in pool.clients:
    if x == client:
      index = i
      break
  if index != -1:
    pool.clients.delete(index)
