# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[os, json, tables, strutils],
  stew/[byteutils, results],
  eth/[keyfile, common, keys]

from nimcrypto/utils import burnMem

type
  NimbusAccount* = object
    privateKey*: PrivateKey
    keystore*: JsonNode
    unlocked*: bool

  AccountsManager* = object
    accounts: Table[EthAddress, NimbusAccount]

proc init*(_: type AccountsManager): AccountsManager =
  discard

proc loadKeystores*(am: var AccountsManager, path: string): Result[void, string]
    {.gcsafe, raises: [OSError].}=
  try:
    createDir(path)
  except OSError, IOError:
    return err("keystore: cannot create directory")

  for filename in walkDirRec(path):
    try:
      var data = json.parseFile(filename)
      let address: EthAddress = hexToByteArray[20](data["address"].getStr())
      am.accounts[address] = NimbusAccount(keystore: data, unlocked: false)
    except JsonParsingError:
      return err("keystore: json parsing error " & filename)
    except ValueError:
      return err("keystore: data parsing error")
    except IOError:
      return err("keystore: data read error")
    except CatchableError as e: # json raises Exception
      return err("keystore: " & e.msg)
    except Exception as e:
      {.warning: "Kludge(BareExcept): `parseFile()` in json vendor package needs to be updated".}
      raiseAssert "Ooops loadKeystores(): name=" & $e.name & " msg=" & e.msg


  ok()

proc getAccount*(am: var AccountsManager, address: EthAddress): Result[NimbusAccount, string] =
  am.accounts.withValue(address, value) do:
    return ok(value[])
  do:
    return err("getAccount: not available " & address.toHex)

proc unlockAccount*(am: var AccountsManager, address: EthAddress, password: string): Result[void, string] =
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

proc lockAccount*(am: var AccountsManager, address: EthAddress): Result[void, string] =
  am.accounts.withValue(address, acc) do:
    acc.unlocked = false
    burnMem(acc.privateKey)
    am.accounts[address] = acc[]
    return ok()
  do:
    return err("getAccount: not available " & address.toHex)

proc numAccounts*(am: AccountsManager): int =
  am.accounts.len

iterator addresses*(am: AccountsManager): EthAddress =
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
