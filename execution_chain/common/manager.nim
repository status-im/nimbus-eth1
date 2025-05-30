# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push gcsafe, raises: [].}

import
  std/[os, json, tables, strutils],
  results,
  eth/keyfile,
  eth/common/[keys, addresses],
  json_serialization

from nimcrypto/utils import burnMem

type
  NimbusAccount* = object
    privateKey*: PrivateKey
    keystore*: JsonNode
    unlocked*: bool

  AccountsManager* = object
    accounts: Table[Address, NimbusAccount]

proc init*(_: type AccountsManager): AccountsManager =
  discard

proc loadKeystores*(am: var AccountsManager, path: string):
                      Result[void, string] =
  try:
    createDir(path)
    for filename in walkDirRec(path):
      var data = Json.loadFile(filename, JsonNode)
      if data.kind != JObject:
        return err("expect json object of keystore data: " & filename)
      if not data.hasKey("address"):
        return err("no 'address' field in keystore data: " & filename)
      let address = Address.fromHex(data["address"].getStr())
      am.accounts[address] = NimbusAccount(keystore: data, unlocked: false)
  except CatchableError as exc:
    return err("loadKeystores: " & exc.msg)

  ok()

proc getAccount*(am: var AccountsManager, address: Address): Result[NimbusAccount, string] =
  am.accounts.withValue(address, value) do:
    return ok(value[])
  do:
    return err("getAccount: not available " & address.toHex)

proc unlockAccount*(am: var AccountsManager, address: Address, password: string): Result[void, string] =
  let accRes = am.getAccount(address)
  if accRes.isErr:
    return err(accRes.error)

  var acc = accRes.get()
  let res = decodeKeyFileJson(acc.keystore, password)
  if res.isOk:
    acc.privateKey = res.get()
    acc.unlocked = true
    am.accounts[address] = acc
    return ok()

  err($res.error)

proc lockAccount*(am: var AccountsManager, address: Address): Result[void, string] =
  am.accounts.withValue(address, acc) do:
    acc.unlocked = false
    burnMem(acc.privateKey)
    am.accounts[address] = acc[]
    return ok()
  do:
    return err("getAccount: not available " & address.toHex)

proc numAccounts*(am: AccountsManager): int =
  am.accounts.len

iterator addresses*(am: AccountsManager): Address =
  for a in am.accounts.keys:
    yield a

proc importPrivateKey*(am: var AccountsManager, fileName: string): Result[void, string] =
  try:
    let pkhex = readFile(fileName)
    let res = PrivateKey.fromHex(pkhex.strip)
    if res.isErr:
      return err("not a valid private key, expect 32 bytes hex")

    let seckey = res.get()
    let acc = seckey.toPublicKey().toCanonicalAddress()

    am.accounts[acc] = NimbusAccount(
      privateKey: seckey,
      unlocked: true
      )

    return ok()
  except CatchableError as ex:
    return err(ex.msg)

{.pop.}
