# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stint,
  ../network/state/state_content,
  ../content_db

suite "Content Database":
  # Note: We are currently not really testing something new here just basic
  # underlying kvstore.
  test "ContentDB basic API":
    let
      db = ContentDB.new("", inMemory = true)
      key = ContentId(UInt256.high()) # Some key

    block:
      let val = db.get(key)

      check:
        val.isNone()
        db.contains(key) == false

    block:
      db.put(key, [byte 0, 1, 2, 3])
      let val = db.get(key)

      check:
        val.isSome()
        val.get() == [byte 0, 1, 2, 3]
        db.contains(key) == true

    block:
      db.del(key)
      let val = db.get(key)

      check:
        val.isNone()
        db.contains(key) == false
