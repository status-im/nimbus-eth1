# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/[os, paths, sequtils, streams],
  pkg/unittest2,
  ../../execution_chain/sync/snap/worker/[mpt, mpt/mpt_debug, worker_desc]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"]
  subDir = ["test_snap"]

proc findFilePath*(
    file: string;
    baseDir: openArray[string] = baseDir;
    repoDir: openArray[string] = repoDir;
    subDir: openArray[string] = subDir;
      ): Result[string,void] =
  for dir in baseDir:
    if dir.dirExists:
      for repo in repoDir:
        if (dir / repo).dirExists:
          for sub in subDir:
            if (dir / repo / sub).dirExists:
              let path = dir / repo / sub / file
              if path.fileExists:
                return ok(path)
  echo "*** File not found \"", file, "\"."
  err()

const
  testFileList = @["sample1.txt.gz"]
  testPathList = block:
    var w: seq[string]
    for f in testFileList:
      let p = f.findFilePath.valueOr:
        raiseAssert "No path for \"" & f & "\""
      w.add p
    w

suite "Snap Data Validator":
  for sample in testPathList:
    let name = sample.splitFile.name
    let (stm,gz) = sample.initUnzip().valueOr:
      raiseAssert "Cannot open \"" & name & "\" for unzip: " & error
    let p = gz.accountRangeFromUnzip()
    if 0 < p.error.len:
      raiseAssert "Error while reading from \"" &  name & "\": " & p.error
    var db: NodeTrieRef

    test name:
      let validated = p.root.validate(p.start, p.pck.accounts, p.pck.proof)
      check validated.isOk
      if validated.isOk:
        db = validated.value

    test name & ", last proof node chopped must fail":
      var proof = p.pck.proof
      proof.setLen(p.pck.proof.len-1)
      check p.root.validate(p.start, p.pck.accounts, proof).isErr

    test name & ", last two accounts chopped must fail":
      # The last account is typically part of the proof, as well. So chopping
      # it would not change anything.
      var accounts = p.pck.accounts
      accounts.setLen(p.pck.accounts.len-2)
      check p.root.validate(p.start, accounts, p.pck.proof).isErr

    test name & ", full tree dump as proof nodes":
      block needDb:
        if db.isNil:
          db = p.root.validate(p.start, p.pck.accounts, p.pck.proof).valueOr:
            skip()
            break needDb
        let proof = db.pairs.mapIt(ProofNode it[1])
        check p.root.validate(p.start, p.pck.accounts, proof).isOk

    test name & ", curbed tree dump as proof nodes must fail":
      block needDb:
        if db.isNil:
          db = p.root.validate(p.start, p.pck.accounts, p.pck.proof).valueOr:
            skip()
            break needDb
        var proof = db.pairs.mapIt(ProofNode it[1])
        proof.setLen(p.pck.proof.len - 1)
        check p.root.validate(p.start, p.pck.accounts, proof).isErr

    stm.close()

# End
