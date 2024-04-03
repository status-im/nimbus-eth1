#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/streams,
  std/strformat,
  stint,
  nimcrypto/hash,
  ../../../vendor/nim-eth/eth/trie/hexary,
  ../../../vendor/nim-eth/eth/trie/db,
  ../mpt_rlp_hash,
  ../mpt_nibbles,
  ../mpt_operations,
  ../utils

import ../mpt {.all.}

from ../../../vendor/nimcrypto/nimcrypto/utils import fromHex

# import std/atomics
# proc atomicInc[T: SomeInteger](location: var Atomic[T]; value: T = 1)

const sampleKvps = @[
   ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "1234"),
   ("0123456789abcdef0123456789abcdef88888888888888888888888888888888", "1234"),
  #("0000000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000123456789abcdef0123456789abcdef"),
  #("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0000000000000000000000000000000000000000000000000000000000000002"),
  # ("1100000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000003"),
  # ("2200000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000004"),
  # ("2211000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000005"),
  # ("3300000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000006"),
  # ("3300000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000007"),
  # ("33000000000000000000000000000000000000000000000000000000000000ff", "0000000000000000000000000000000000000000000000000000000000000008"),
  # ("4400000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000009"),
  # ("4400000011000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000000000000000000000000000000000a"),
  # ("5500000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000000000000000000000000000000000b"),
  # ("5500000000000000000000000000000000000000000000000000000000001100", "000000000000000000000000000000000000000000000000000000000000000c"),
]

iterator hexKvpsToBytes32(kvps: openArray[tuple[key: string, value: string]]):
    tuple[key: array[32, byte], value: seq[byte]] =
  for (hexKey, hexValue) in kvps:
    yield (hexToBytesArray[32](hexKey), hexValue.fromHex)

let emptyRlpHash = "56E81F171BCC55A6FF8345E692C0F86E5B48E01B996CADC001622FB5E363B421".fromHex
var db2 = newMemoryDB()
var trie = initHexaryTrie(db2)
var container: DiffLayer

for (key, value) in sampleKvps.hexKvpsToBytes32():
  echo &"Adding {key.toHex} --> {value.toHex}"
  #let key = "A".keccakHash.data
  trie.put(key, value)
  container.put(Nibbles64(bytes: key), value)

echo "\nDumping kvps in DB"
for kvp in db2.pairsInMemoryDB():
  if kvp[0][0..^1] != emptyRlpHash[0..^1]:
    echo &"{kvp[0].toHex} => {kvp[1].toHex}"

echo ""
var rootHash = container.getOrComputeHash
echo "\nDumping tree:\n"
container.root.printTree(newFileStream(stdout), rootHash)

echo ""
echo &"Legacy root hash: {trie.rootHash.data.toHex}" #"0xe9e2935138352776cad724d31c9fa5266a5c593bb97726dd2a908fe6d53284df"
echo &"BART   root hash: {container.getOrComputeHash[].toHex}"


#[


Adding 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef --> 1234
Adding 0123456789abcdef0123456789abcdef88888888888888888888888888888888 --> 1234

Dumping kvps in DB
22cfdc621a743d628b8492366840f1ba5dfe7be3f5da2e039b0e3a72ddd9ed6c =>  f839d4903123456789abcdef0123456789abcdef82123480808080808080d490388888888888888888888888888888888212348080808080808080
73209468d8d1058c7f3140c030f10ef2a7b09b25e891f42dcf33a248b0fbd8f0 =>  f391000123456789abcdef0123456789abcdefa022cfdc621a743d628b8492366840f1ba5dfe7be3f5da2e039b0e3a72ddd9ed6c

       [                                                                                                                                                  ]
           [                                                ]                        [                                            ]
f8  39  d4  90    3123456789abcdef0123456789abcdef  82  1234  80 80 80 80 80 80 80 d4  90 38888888888888888888888888888888 82 1234 80 80 80 80 80 80 80 80
list ahead; size in 1 byte                          2-bytes string ahead           20 bytes list ahead
    size of list: 57                                    leaf 1? value                  16 bytes string ahead 
        20 bytes list ahead                                   empty strings...            string: 3 = odd leaf marker; the rest: second leaf's lower path
            16 bytes string ahead                                                                                          2-bytes string ahead
                  3 = odd leaf marker; the rest: first leaf's lower path                                                      leaf 2? value


[[3123456789abcdef0123456789abcdef, 1234], nil, nil, nil, nil, nil, nil, nil, [], nil, nil, nil, nil, nil, nil, nil, nil]

[ offset 0: [leaf 1 lower path + marker, leaf 1 value], ...(nils)... , offset 8: [leaf 2 lower path + marker, leaf 2 value], ...(nils)... ]  (17 children)

f3  91  00  0123456789abcdef0123456789abcdef a0  22cfdc621a743d628b8492366840f1ba5dfe7be3f5da2e039b0e3a72ddd9ed6c
f3   list of 51 items                        32 bytes tring
    string 17 bytes                              hash of above
        extention node marker
            extension node path
                                             

Leaf: d4903123456789abcdef0123456789abcdef821234
Leaf: d49038888888888888888888888888888888821234
Branch: f839d4903123456789abcdef0123456789abcdef82123480808080808080d490388888888888888888888888888888888212348080808080808080
Extension: f291000123456789abcdef0123456789abcdefa022cfdc621a743d628b8492366840f1ba5dfe7be3f5da2e039b0e3a72ddd9ed6c

Dumping tree:

0123456789abcdef0123456789abcdef                                  Extension     Hash: f58249e0398995cea68f155e0ad9855bc2273983c2cbb470ad24a43ea7ac687d
                                0|                                 Branch        Hash: 22cfdc621a743d628b8492366840f1ba5dfe7be3f5da2e039b0e3a72ddd9ed6c
                                 0123456789abcdef0123456789abcdef  Leaf          Hash: d4903123456789abcdef0123456789abcdef821234  Value: 1234
                                 88888888888888888888888888888888  Leaf          Hash: d49038888888888888888888888888888888821234  Value: 1234

Legacy root hash: 73209468d8d1058c7f3140c030f10ef2a7b09b25e891f42dcf33a248b0fbd8f0
BART   root hash: f58249e0398995cea68f155e0ad9855bc2273983c2cbb470ad24a43ea7ac687d  
]#