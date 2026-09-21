# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/tables,
  results,
  ./kvt_desc

# ------------------------------------------------------------------------------
# Public functions: get function
# ------------------------------------------------------------------------------

func layersLen*(db: KvtTxRef; key: openArray[byte]|seq[byte]): Opt[int] =
  ## Returns the size of the value associated with `key`.
  ##
  when key isnot seq[byte]:
    let key = @key

  db.sTab.withValue(key, item):
    return Opt.some(item[].len())

  Opt.none(int)

func layersHasKey*(db: KvtTxRef; key: openArray[byte]|seq[byte]): bool =
  ## Return `true` if the argument key has a pending write.
  ##
  db.layersLen(key).isSome()

func layersGet*(db: KvtTxRef; key: openArray[byte]|seq[byte]): Opt[seq[byte]] =
  ## Find an item in the pending write set. An `ok()` result might contain an
  ## empty value if it is stored that way (ie a pending delete).
  ##
  when key isnot seq[byte]:
    let key = @key

  db.sTab.withValue(key, item):
    return Opt.some(item[])

  Opt.none(seq[byte])

# ------------------------------------------------------------------------------
# Public functions: put function
# ------------------------------------------------------------------------------

func layersPutMove*(db: KvtTxRef; key: openArray[byte]; data: var seq[byte]) =
  ## Store a (potentally empty) value in the write set, taking over the
  ## contents of `data` which is left empty
  swap(db.sTab.mgetOrPut(@key, EmptyBlob), data)
  data.setLen(0)

func layersPut*(db: KvtTxRef; key: openArray[byte]; data: openArray[byte]) =
  ## Store a (potentally empty) value in the write set
  var data = @data
  db.layersPutMove(key, data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
