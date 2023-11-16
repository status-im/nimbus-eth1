# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, strformat, strutils],
  eth/common,
  stew/byteutils,
  ../../nimbus/sync/[protocol, snap/range_desc],
  ./gunzip

import
  nimcrypto/utils except toHex

type
  UndumpState = enum
    UndumpStoragesHeader
    UndumpStoragesRoot
    UndumpSlotsHeader
    UndumpSlotsAccount
    UndumpSlotsRoot
    UndumpSlotsList
    UndumpProofs
    UndumpCommit
    UndumpError
    UndumpSkipUntilCommit

  UndumpStorages* = object
    ## Palatable output for iterator
    root*: Hash256
    data*: AccountStorageRange
    seenAccounts*: int
    seenStorages*: int

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template say(args: varargs[untyped]) =
  # echo args
  discard

proc toByteSeq(s: string): seq[byte] =
  utils.fromHex(s)

proc fromHex(T: type Hash256; s: string): T =
  result.data = ByteArray32.fromHex(s)

proc fromHex(T: type NodeKey; s: string): T =
  ByteArray32.fromHex(s).T

proc fromHex(T: type NodeTag; s: string): T =
  UInt256.fromBytesBE(ByteArray32.fromHex(s)).T

# ------------------------------------------------------------------------------
# Public capture
# ------------------------------------------------------------------------------

proc dumpStorages*(
    root: Hash256;
    data: AccountStorageRange
      ): string =
  ## Dump account and storage data in parseable Ascii text
  proc ppStr(blob: Blob): string =
    blob.toHex

  proc ppStr(proof: SnapProof): string =
    proof.to(Blob).ppStr

  proc ppStr(hash: Hash256): string =
    hash.data.toHex

  proc ppStr(key: NodeKey): string =
    key.ByteArray32.toHex

  result = "storages " & $data.storages.len & " " & $data.proof.len & "\n"
  result &= root.ppStr & "\n"

  for n in 0 ..< data.storages.len:
    let slots = data.storages[n]
    result &= "# -- " & $n & " --\n"
    result &= "slots " & $slots.data.len & "\n"
    result &= slots.account.accKey.ppStr & "\n"
    result &= slots.account.storageRoot.ppStr & "\n"

    for i in 0 ..< slots.data.len:
      result &= slots.data[i].slotHash.ppStr & " "
      result &= slots.data[i].slotData.ppStr & "\n"

  if 0 < data.proof.len:
    result &= "# ----\n"
    for n in 0 ..< data.proof.len:
      result &= data.proof[n].ppStr & "\n"

  result &= "commit\n"

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpNextStorages*(gzFile: string): UndumpStorages =
  var
    state = UndumpStoragesHeader
    data: UndumpStorages
    nAccounts = 0u
    nProofs = 0u
    nSlots = 0u
    seenAccounts = 0
    seenStorages = 0

  if not gzFile.fileExists:
    raiseAssert &"No such file: \"{gzFile}\""

  for lno,line in gzFile.gunzipLines:
    if line.len == 0 or line[0] == '#':
      continue
    var flds = line.split
    #echo ">>> ",
    #    " lno=", lno,
    #    " state=", state,
    #    " nAccounts=", nAccounts,
    #    " nProofs=", nProofs,
    #    " nSlots=", nSlots,
    #    " flds=", flds

    case state:
    of UndumpSkipUntilCommit:
      if flds.len == 1 and flds[0] == "commit":
        state = UndumpStoragesHeader

    of UndumpStoragesHeader, UndumpError:
      if flds.len == 3 and flds[0] == "storages":
        nAccounts = flds[1].parseUInt
        nProofs = flds[2].parseUInt
        data.reset
        state = UndumpStoragesRoot
        seenStorages.inc
        continue
      if 1 < flds.len and flds[0] == "accounts":
        state = UndumpSkipUntilCommit
        seenAccounts.inc
        continue
      if state != UndumpError:
         state = UndumpError
         say &"*** line {lno}: expected storages header, got {line}"

    of UndumpStoragesRoot:
      if flds.len == 1:
        data.root = Hash256.fromHex(flds[0])
        if 0 < nAccounts:
          state = UndumpSlotsHeader
          continue
        state = UndumpCommit
        continue
      state = UndumpError
      say &"*** line {lno}: expected storages state root, got {line}"

    of UndumpSlotsHeader:
      if flds.len == 2 and flds[0] == "slots":
        nSlots = flds[1].parseUInt
        state = UndumpSlotsAccount
        continue
      state = UndumpError
      say &"*** line {lno}: expected slots header, got {line}"

    of UndumpSlotsAccount:
      if flds.len == 1:
        data.data.storages.add AccountSlots(
          account: AccountSlotsHeader(
          accKey:  NodeKey.fromHex(flds[0])))
        state = UndumpSlotsRoot
        continue
      state = UndumpError
      say &"*** line {lno}: expected slots account, got {line}"

    of UndumpSlotsRoot:
      if flds.len == 1:
        data.data.storages[^1].account.storageRoot = Hash256.fromHex(flds[0])
        state = UndumpSlotsList
        continue
      state = UndumpError
      say &"*** line {lno}: expected slots storage root, got {line}"

    of UndumpSlotsList:
      if flds.len == 2:
        data.data.storages[^1].data.add SnapStorage(
          slotHash: Hash256.fromHex(flds[0]),
          slotData: flds[1].toByteSeq)
        nSlots.dec
        if 0 < nSlots:
          continue
        nAccounts.dec
        if 0 < nAccounts:
          state = UndumpSlotsHeader
          continue
        if 0 < nProofs:
          state = UndumpProofs
          continue
        state = UndumpCommit
        continue
      state = UndumpError
      say &"*** line {lno}: expected slot data, got {line}"

    of UndumpProofs:
      if flds.len == 1:
        data.data.proof.add flds[0].toByteSeq.to(SnapProof)
        nProofs.dec
        if nProofs <= 0:
          state = UndumpCommit
          # KLUDGE: set base (field was later added)
          if 0 < data.data.storages.len:
            let topList = data.data.storages[^1]
            if 0 < topList.data.len:
              data.data.base = topList.data[0].slotHash.to(NodeTag)
        continue
      state = UndumpError
      say &"*** expected proof data, got {line}"

    of UndumpCommit:
      if flds.len == 1 and flds[0] == "commit":
        data.seenAccounts = seenAccounts
        data.seenStorages = seenStorages
        yield data
        state = UndumpStoragesHeader
        continue
      state = UndumpError
      say &"*** line {lno}: expected commit, got {line}"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
