# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  accounts/manager,
  stew/results,
  eth/keys

export manager

type
  EthContext* = ref object
    am*: AccountsManager
    # You should only create one instance of the RNG per application / library
    # Ref is used so that it can be shared between components
    rng*: ref BrHmacDrbgContext

proc newEthContext*(): EthContext =
  result = new(EthContext)
  result.am = AccountsManager.init()
  result.rng = newRng()

proc randomPrivateKey*(ctx: EthContext): PrivateKey =
  random(PrivateKey, ctx.rng[])

proc randomKeyPair*(ctx: EthContext): KeyPair =
  random(KeyPair, ctx.rng[])

proc hexToKeyPair*(ctx: EthContext, hexPrivateKey: string): Result[KeyPair, string] =
  if hexPrivateKey.len == 0:
    let privateKey = ctx.randomPrivateKey()
    ok(privateKey.toKeyPair())
  else:
    let res = PrivateKey.fromHex(hexPrivateKey)
    if res.isErr:
      return err($res.error)
    ok(res.get().toKeyPair())
