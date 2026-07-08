# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Download packet formats
## -----------------------
##
## * Accounts:
##   + key65: <col, root, start>
##   + value: <limit, accounts, proof, peerID>
##   where
##   + col:      `cAccount`
##   + root:     `StateRoot`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + accounts: `seq[SnapAccount]`
##   + proof:    `seq[ProofNode]`
##   + peerID:   `Hash`
##
## * Storage slots:
##   + key97: <col, root, account, start>
##   + value: <limit, slot, proof, peerID>
##   where
##   + col:      `cStoSlot`
##   + root:     `StateRoot`
##   * account:  `ItemKey`
##   + start:    `ItemKey`
##   + limit:    `ItemKey`
##   + slot:     `seq[StorageItem]`
##   + proof:    `seq[ProofNode]`
##   + peerID:   `Hash`
##
## * ByteCode:
##   + key65: <col, root, start>
##   + value: <limit, code, peerID>
##   where
##   + col:      `cByteCode`
##   + root:     `StateRoot`
##   * start:    `ItemKey`
##   + limit:    `ItemKey`
##   + codes:    `seq[(CodeHash,CodeItem)]`
##   + peerID:   `Hash`
##

{.push raises: [].}

import
  pkg/[eth/common, results],
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ../mpt_desc,
  ./[cache_api1, cache_api65, cache_api97,
     cache_const, cache_desc, cache_iter, cache_rlp]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getAccount*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): AccountDataResult =
  let data = db.get65(cAccount, root, start).valueOr:
    return err(error)
  data.decodeAccountData()

proc putAccount*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    accounts: seq[SnapAccount];
    proof: seq[ProofNode];
    peerID: Hash;
      ): PutResult =
  db.put65(
    cAccount, root, start, encodeAccountData(limit, accounts, proof, peerID))

proc delAccount*(db: MptAsmRef; root: StateRoot; start: ItemKey): DelResult =
  db.del65(cAccount, root, start)

proc clearAccount*(db: MptAsmRef): DelResult =
  db.clr1 cAccount

iterator walkAccount*(db: MptAsmRef): WalkAccountData =
  for (key1,key2,value) in db.adb.colWalk65 cAccount.key65():
    let
      root = StateRoot(key1)
      start = key2.to(ItemKey)
      w = value.decodeAccountData().valueOr:
        var oops: WalkAccountData
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w, "")

iterator walkAccount*(db: MptAsmRef, root: StateRoot): WalkAccountData =
  ## Variant of `walkAccount()` for fixed `root`
  for (key1,key2,value) in db.adb.colWalk65 cAccount.key65(root):
    if StateRoot(key1) != root:
      break
    let
      start = key2.to(ItemKey)
      w = value.decodeAccountData().valueOr:
        var oops: WalkAccountData
        oops.root = root
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, start, w, "")

# -------------

proc getStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    account: ItemKey;
    start: ItemKey;
      ): StoSlotDataResult =
  let data = db.get97(cStoSlot, root, account, start).valueOr:
    return err(error)
  data.decodeStoSlotData()

proc putStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
    limit: ItemKey;
    slot: seq[StorageItem];
    proof: seq[ProofNode];
    peerID: Hash;
      ): PutResult =
  db.put97(
    cStoSlot, root, acc, start, encodeStoSlotData(limit, slot, proof, peerID))

proc putStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    slot: seq[StorageItem];
    peerID: Hash;
      ): PutResult =
  db.put97(
    cStoSlot, root, acc, low(ItemKey),
    encodeStoSlotData(high(ItemKey), slot, EmptyProof, peerID))

proc delStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
    start: ItemKey;
      ): DelResult =
  db.del97(cStoSlot, root, acc, start)

proc clearStoSlot*(db: MptAsmRef): DelResult =
  db.clr1 cStoSlot

iterator walkStoSlot*(
    db: MptAsmRef;
    root: StateRoot;
    acc: ItemKey;
      ): WalkStoSlotData =
  ## Variant of `walkStoSlot()` for fixed `root`
  let aHash = acc.to(Hash32)
  for (k1,k2,k3,val) in db.adb.colWalk97 cStoSlot.key97(root, aHash):
    if k1.to(StateRoot) != root or
       k2.to(ItemKey) != acc:
      break
    let
      start = k3.to(ItemKey)
      w = val.decodeStoSlotData().valueOr:
        var oops: WalkStoSlotData
        oops.root = root
        oops.account = acc
        oops.start = start
        oops.error = error
        yield oops
        continue
    yield (root, acc, start, w, "")

# -------------

proc getByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
      ): ByteCodeDataResult =
  let data = db.get65(cByteCode, root, start).valueOr:
    return err(error)
  data.decodeByteCodeData()

proc putByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
    limit: ItemKey;
    codes: seq[(CodeHash,CodeItem)];
    peerID: Hash;
      ): PutResult =
  db.put65(cByteCode, root, start, encodeByteCodeData(limit, codes, peerID))

proc delByteCode*(db: MptAsmRef; root: StateRoot; start: ItemKey): DelResult =
  db.del65(cByteCode, root, start)

proc clearByteCode*(db: MptAsmRef): DelResult =
  db.clr1 cByteCode

iterator walkByteCode*(
    db: MptAsmRef;
    root: StateRoot;
    start: ItemKey;
      ): WalkByteCodeData =
  ## Variant of `walkAccount()` for fixed `root` and `start` account
  let startHash = start.to(Hash32)
  for (key1,key2,value) in db.adb.colWalk65 cByteCode.key65(root, startHash):
    if StateRoot(key1) != root:
      break
    let
      start2 = key2.to(ItemKey)
      w = value.decodeByteCodeData().valueOr:
        var oops: WalkByteCodeData
        oops.root = root
        oops.start = start2
        oops.error = error
        yield oops
        continue
    yield (root, start2, w, "")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
