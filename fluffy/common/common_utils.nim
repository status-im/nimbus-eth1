# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[os, strutils],
  chronicles,
  eth/common,
  stew/[io2, arrayops],
  eth/p2p/discoveryv5/enr

func fromBytes*(T: type KeccakHash, hash: openArray[byte]): T =
  doAssert(hash.len() == 32)
  KeccakHash(array[32, byte].initCopyFrom(hash))

iterator strippedLines(filename: string): string {.raises: [ref IOError].} =
  for line in lines(filename):
    let stripped = strip(line)
    if stripped.startsWith('#'): # Comments
      continue

    if stripped.len > 0:
      yield stripped

proc addBootstrapNode(bootstrapAddr: string, bootstrapEnrs: var seq[Record]) =
  let res = enr.Record.fromURI(bootstrapAddr)
  if res.isOk():
    bootstrapEnrs.add res.value
  else:
    warn "Ignoring invalid bootstrap ENR", bootstrapAddr, error = $res.error

proc loadBootstrapFile*(bootstrapFile: string, bootstrapEnrs: var seq[Record]) =
  if bootstrapFile.len == 0:
    return
  let ext = splitFile(bootstrapFile).ext
  if cmpIgnoreCase(ext, ".txt") == 0 or cmpIgnoreCase(ext, ".enr") == 0:
    try:
      for ln in strippedLines(bootstrapFile):
        addBootstrapNode(ln, bootstrapEnrs)
    except IOError as e:
      fatal "Could not read bootstrap file", msg = e.msg
      quit 1
  else:
    fatal "Unknown bootstrap file format", ext
    quit 1

# Note:
# Currently just works with the network private key stored as hex in a file.
# In the future it would be nice to re-use keystore from nimbus-eth2 for this.
# However that would require the pull the keystore.nim and parts of
# keystore_management.nim out of nimbus-eth2.
proc getPersistentNetKey*(
    rng: var HmacDrbgContext, keyFilePath: string
): tuple[key: PrivateKey, newNetKey: bool] =
  logScope:
    key_file = keyFilePath

  if fileAccessible(keyFilePath, {AccessFlags.Find}):
    info "Network key file is present, reading key"

    let readResult = readAllChars(keyFilePath)
    if readResult.isErr():
      fatal "Could not load network key file", error = ioErrorMsg(readResult.error)
      quit QuitFailure

    let netKeyInHex = readResult.get()
    if netKeyInHex.len() == 64:
      let netKey = PrivateKey.fromHex(netKeyInHex)
      if netKey.isOk():
        info "Network key was successfully read"
        (netKey.get(), false)
      else:
        fatal "Invalid private key from file", error = netKey.error
        quit QuitFailure
    else:
      fatal "Invalid length of private in file"
      quit QuitFailure
  else:
    info "Network key file is missing, creating a new one"
    let key = PrivateKey.random(rng)

    if (let res = io2.writeFile(keyFilePath, $key); res.isErr):
      fatal "Failed to write the network key file", error = ioErrorMsg(res.error)
      quit 1

    info "New network key file was created"

    (key, true)

proc getPersistentEnr*(enrFilePath: string): Opt[enr.Record] =
  logScope:
    enr_file = enrFilePath

  if fileAccessible(enrFilePath, {AccessFlags.Find}):
    info "ENR file is present, reading ENR"

    let readResult = readAllChars(enrFilePath)
    if readResult.isErr():
      warn "Could not load ENR file", error = ioErrorMsg(readResult.error)
      return Opt.none(enr.Record)

    let enrUri = readResult.get()

    let res = enr.Record.fromURI(enrUri)
    if res.isErr():
      warn "Could not decode ENR from ENR file"
      Opt.none(enr.Record)
    else:
      Opt.some(res.value)
  else:
    warn "Could not find ENR file. Was it manually deleted?"
    Opt.none(enr.Record)
