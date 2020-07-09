import
  eth/common, eth/trie/[db, nibbles], algorithm,
  ./witness_types

type
  KeyHash* = array[32, byte]

  KeyData* = object
    visited*: bool
    hash*: KeyHash
    case storageMode*: bool
    of true:
      storageSlot*: StorageSlot
    of false:
      storageKeys*: MultikeysRef
      address*: EthAddress
      codeTouched*: bool

  Multikeys* = object
    keys*: seq[KeyData]

  MultikeysRef* = ref Multikeys

  Group* = object
    first*, last*: int16

  BranchGroup* = object
    mask*: uint
    groups*: array[16, Group]

  AccountKey* = object
    address*: EthAddress
    codeTouched*: bool
    storageKeys*: MultikeysRef

  MatchGroup* = object
    match*: bool
    group*: Group

func cmpHash(a, b: KeyHash): int =
  var i = 0
  var m = min(a.len, b.len)
  while i < m:
    result = a[i].int - b[i].int
    if result != 0: return
    inc(i)
  result = a.len - b.len

func cmpHash(a, b: KeyData): int =
  cmpHash(a.hash, b.hash)

func getNibble(x: openArray[byte], i: int): byte =
  if(i and 0x01) == 0x01:
    result = x[i shr 1] and 0x0F
  else:
    result = x[i shr 1] shr 4

func compareNibbles(x: openArray[byte], start: int, n: NibblesSeq): bool =
  var i = 0
  while i < n.len:
    if getNibble(x, start + i) != n[i]:
      return false
    inc i
  result = true

proc newMultiKeys*(keys: openArray[AccountKey]): MultikeysRef =
  result = new Multikeys
  result.keys = newSeq[KeyData](keys.len)
  for i, a in keys:
    result.keys[i] = KeyData(
      storageMode: false,
      hash: keccak(a.address).data,
      address: a.address,
      codeTouched: a.codeTouched,
      storageKeys: a.storageKeys)
  result.keys.sort(cmpHash)

proc newMultiKeys*(keys: openArray[StorageSlot]): MultikeysRef =
  result = new Multikeys
  result.keys = newSeq[KeyData](keys.len)
  for i, a in keys:
    result.keys[i] = KeyData(storageMode: true, hash: keccak(a).data, storageSlot: a)
  result.keys.sort(cmpHash)

# never mix storageMode!
proc add*(m: MultikeysRef, address: EthAddress, codeTouched: bool, storageKeys = MultikeysRef(nil)) =
  m.keys.add KeyData(
    storageMode: false,
    hash: keccak(address).data,
    address: address,
    codeTouched: codeTouched,
    storageKeys: storageKeys)

proc add*(m: MultikeysRef, slot: StorageSlot) =
  m.keys.add KeyData(storageMode: true, hash: keccak(slot).data, storageSlot: slot)

proc sort*(m: MultikeysRef) =
  m.keys.sort(cmpHash)

func initGroup*(m: MultikeysRef): Group =
  type T = type result.last
  result = Group(first: 0.T, last: (m.keys.len - 1).T)

func groups*(m: MultikeysRef, parentGroup: Group, depth: int): BranchGroup =
  # similar to a branch node, the product of this func
  # is a 16 bits bitmask and an array of max 16 groups
  # if the bit is set, the n-th elem of array have a group
  # each group consist of at least one key
  var g = Group(first: parentGroup.first)
  var nibble = getNibble(m.keys[g.first].hash, depth)
  for i in parentGroup.first..parentGroup.last:
    let currNibble = getNibble(m.keys[i].hash, depth)
    if currNibble != nibble:
      # close current group and start a new group
      g.last = i - 1
      setBranchMaskBit(result.mask, nibble.int)
      result.groups[nibble.int] = g
      nibble = currNibble
      g.first = i

  # always close the last group
  g.last = parentGroup.last
  setBranchMaskBit(result.mask, nibble.int)
  result.groups[nibble.int] = g

func groups*(m: MultikeysRef, depth: int, n: NibblesSeq, parentGroup: Group): MatchGroup =
  # using common-prefix comparison, this func
  # will produce one match group or no match at all
  var g = Group(first: parentGroup.first)

  if compareNibbles(m.keys[g.first].hash, depth, n):
    var i = g.first + 1
    while i <= parentGroup.last:
      if not compareNibbles(m.keys[i].hash, depth, n):
        g.last = i - 1
        # case 1: match and no match
        return MatchGroup(match: true, group: g)
      inc i

    # case 2: all is a match group
    g.last = parentGroup.last
    return MatchGroup(match: true, group: g)

  # no match came first, skip no match
  # we only interested in a match group
  var i = g.first + 1
  while i <= parentGroup.last:
    if compareNibbles(m.keys[i].hash, depth, n):
      g.first = i
      break
    inc i

  if i <= parentGroup.last:
    while i <= parentGroup.last:
      if not compareNibbles(m.keys[i].hash, depth, n):
        # case 3: no match, match, and no match
        g.last = i - 1
        return MatchGroup(match: true,  group: g)
      inc i

    # case 4: no match and match
    g.last = parentGroup.last
    return MatchGroup(match: true, group: g)

  # case 5: no match at all
  result = MatchGroup(match: false, group: g)

func isValidMatch(mg: MatchGroup): bool {.inline.} =
  result = mg.match and mg.group.first == mg.group.last

proc visitMatch*(m: var MultikeysRef, mg: MatchGroup, depth: int): KeyData =
  doAssert(mg.isValidMatch, "Multiple identical keys are not allowed")
  m.keys[mg.group.first].visited = true
  result = m.keys[mg.group.first]
