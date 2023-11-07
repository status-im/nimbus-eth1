# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
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
    UndumpHeader
    UndumpStateRoot
    UndumpBase
    UndumpAccountList
    UndumpProofs
    UndumpCommit
    UndumpError
    UndumpSkipUntilCommit

  UndumpAccounts* = object
    ## Palatable output for iterator
    root*: Hash256
    base*: NodeTag
    data*: PackedAccountRange
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

proc dumpAccounts*(
    root: Hash256;
    base: NodeTag;
    data: PackedAccountRange;
      ): string =
  ## Dump accounts data in parseable Ascii text
  proc ppStr(blob: Blob): string =
    blob.toHex

  proc ppStr(proof: SnapProof): string =
    proof.to(Blob).ppStr

  proc ppStr(hash: Hash256): string =
    hash.data.toHex

  proc ppStr(key: NodeKey): string =
    key.ByteArray32.toHex

  result = "accounts " & $data.accounts.len & " " & $data.proof.len & "\n"

  result &= root.ppStr & "\n"
  result &= base.to(Hash256).ppStr & "\n"

  for n in 0 ..< data.accounts.len:
    result &= data.accounts[n].accKey.ppStr & " "
    result &= data.accounts[n].accBlob.ppStr & "\n"

  if 0 < data.proof.len:
    result &= "# ----\n"
    for n in 0 ..< data.proof.len:
      result &= data.proof[n].ppStr & "\n"

  result &= "commit\n"

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpNextAccount*(gzFile: string): UndumpAccounts =
  var
    state = UndumpHeader
    data: UndumpAccounts
    nAccounts = 0u
    nProofs = 0u
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
    #    " flds=", flds

    case state:
    of UndumpSkipUntilCommit:
      if flds.len == 1 and flds[0] == "commit":
        state = UndumpHeader

    of UndumpHeader, UndumpError:
      if flds.len == 3 and flds[0] == "accounts":
        nAccounts = flds[1].parseUInt
        nProofs = flds[2].parseUInt
        data.reset
        state = UndumpStateRoot
        seenAccounts.inc
        continue
      if 1 < flds.len and flds[0] == "storages":
        seenStorages.inc
        state = UndumpSkipUntilCommit
        continue
      if state != UndumpError:
         state = UndumpError
         say &"*** line {lno}: expected header, got {line}"

    of UndumpStateRoot:
      if flds.len == 1:
        data.root = Hash256.fromHex(flds[0])
        state = UndumpBase
        continue
      state = UndumpError
      say &"*** line {lno}: expected state root, got {line}"

    of UndumpBase:
      if flds.len == 1:
        data.base = NodeTag.fromHex(flds[0])
        if 0 < nAccounts:
          state = UndumpAccountList
          continue
        if 0 < nProofs:
          state = UndumpProofs
          continue
        state = UndumpCommit
        continue
      state = UndumpError
      say &"*** line {lno}: expected account base, got {line}"

    of UndumpAccountList:
      if flds.len == 2:
        data.data.accounts.add PackedAccount(
          accKey: NodeKey.fromHex(flds[0]),
          accBlob: flds[1].toByteSeq)
        nAccounts.dec
        if 0 < nAccounts:
          continue
        if 0 < nProofs:
          state = UndumpProofs
          continue
        state = UndumpCommit
        continue
      state = UndumpError
      say &"*** line {lno}: expected account data, got {line}"

    of UndumpProofs:
      if flds.len == 1:
        data.data.proof.add flds[0].toByteSeq.to(SnapProof)
        nProofs.dec
        if nProofs <= 0:
          state = UndumpCommit
        continue
      state = UndumpError
      say &"*** expected proof data, got {line}"

    of UndumpCommit:
      if flds.len == 1 and flds[0] == "commit":
        data.seenAccounts = seenAccounts
        data.seenStorages = seenStorages
        yield data
        state = UndumpHeader
        continue
      state = UndumpError
      say &"*** line {lno}: expected commit, got {line}"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
