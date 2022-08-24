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
  std/[os, sequtils, strformat, strutils],
  eth/common,
  nimcrypto,
  stew/byteutils,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/hexary_desc,
  ./gunzip

type
  UndumpState = enum
    UndumpHeader
    UndumpStateRoot
    UndumpBase
    UndumpAccounts
    UndumpProofs
    UndumpCommit
    UndumpError

  UndumpProof* = object
    ## Palatable output for iterator
    root*: Hash256
    base*: NodeTag
    data*: PackedAccountRange

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template say(args: varargs[untyped]) =
  # echo args
  discard

proc toByteSeq(s: string): seq[byte] =
  nimcrypto.fromHex(s)

proc fromHex(T: type Hash256; s: string): T =
  result.data = ByteArray32.fromHex(s)

proc fromHex(T: type NodeTag; s: string): T =
  UInt256.fromBytesBE(ByteArray32.fromHex(s)).T

# ------------------------------------------------------------------------------
# Public capture
# ------------------------------------------------------------------------------

proc dumpAccountProof*(
    root: Hash256;
    base: NodeTag;
    data: PackedAccountRange;
      ): string =
  ## Dump accounts data in parseable Ascii text
  proc ppStr(blob: Blob): string =
    blob.mapIt(it.toHex(2)).join.toLowerAscii

  proc ppStr(hash: Hash256): string =
    hash.data.mapIt(it.toHex(2)).join.toLowerAscii

  result = "accounts " & $data.accounts.len & " " & $data.proof.len & "\n"

  result &= root.ppStr & "\n"
  result &= base.to(Hash256).ppStr & "\n"

  for n in 0 ..< data.accounts.len:
    result &= data.accounts[n].accHash.ppStr & " "
    result &= data.accounts[n].accBlob.ppStr & "\n"

  for n in 0 ..< data.proof.len:
    result &= data.proof[n].ppStr & "\n"

  result &= "commit\n"

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpNextProof*(gzFile: string): UndumpProof =
  var
    line = ""
    lno = 0
    state = UndumpHeader
    data: UndumpProof
    nAccounts = 0u
    nProofs = 0u

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
    of UndumpHeader, UndumpError:
      if flds.len == 3 and flds[0] == "accounts":
        nAccounts = flds[1].parseUInt
        nProofs = flds[2].parseUInt
        data.reset
        state = UndumpStateRoot
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
        state = UndumpAccounts
        continue
      state = UndumpError
      say &"*** line {lno}: expected account base, got {line}"

    of UndumpAccounts:
      if flds.len == 2:
        data.data.accounts.add PackedAccount(
          accHash: Hash256.fromHex(flds[0]),
          accBlob: flds[1].toByteSeq)
        nAccounts.dec
        if nAccounts <= 0:
          state = UndumpProofs
        continue
      state = UndumpError
      say &"*** line {lno}: expected account data, got {line}"

    of UndumpProofs:
      if flds.len == 1:
        data.data.proof.add flds[0].toByteSeq
        nProofs.dec
        if nProofs <= 0:
          state = UndumpCommit
        continue
      state = UndumpError
      say &"*** expected proof data, got {line}"

    of UndumpCommit:
      if flds.len == 1 and flds[0] == "commit":
        yield data
        state = UndumpHeader
        continue
      state = UndumpError
      say &"*** line {lno}: expected commit, got {line}"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
