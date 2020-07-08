# How to build multiproof block witness from state trie

The [block witness spec](https://github.com/ethereum/stateless-ethereum-specs/blob/master/witness.md) define the
binary format in BNF form notation. It will help the trie builder implementer quickly implement a working block
witness parser using simple LL(1) parser.

If you have a working `Hexary Trie` implementation, you'll also probably can quickly implement a working witness
builder for a single proof. You don't need to alter the algorithm, you only need to alter the output.
The output will not an `Account` anymore, but binary block witness containing one proof for single `Account`.

However, the block witness spec does not  provide specific implementation algorithms. You might already know
how to generate a single proof block witness, but how to generate a block witness contains multiple proofs?

You can try to read [turbo geth's multiproof algorithm](https://github.com/ledgerwatch/turbo-geth/blob/master/docs/programmers_guide/guide.md).
And I will try to provide an alternative implementation, a simpler to understand algorithm that require only minimum changes
in the single proof generation algorithm and delegate the details into `multi-keys` algorithm.

## Basic single proof

I assume you have basic knowledge of how `Merkle Patricia Trie` works. As you probably already know, `Hexary Trie` have 4 types of node:

* __Leaf Node__
	A leaf node is a two elements node: [nibbles, value].
* __Extension Node__
	An extension node also a two elements node: [nibbles, hash to next node].
* __Branch Node__
	A branch node is a 17 elements node: [0, 1, ..., 16, value]. All of 0th to 16th elements are a hash to next node.

Every time you request a node using a hash key, you'll get one of the 3 types of node above.

### Deviation from yellow paper

* In the Yellow Paper, the `hash to next node` may be replaced by the next node directly if the RLP encoded node bytes count
  less than 32. But in a real Ethereum State trie, this never happened for account trie. An empty RLP encoded `Account` will have length of 70.
  Combined with the Hex Prefix encoding of nibbles, it will be more than 70 bytes. Short Rlp node only exist in storage trie
  with depth >= 9.
* In Yellow Paper, the 17th elem of the `Branch Node` can contains a value. But it always empty in a real Ethereum State trie.
  The block witness spec also ignore this 17th elem when encoding or decoding `Branch Node`.
  This can happen because in Ethereum `Secure Hexary Trie`, every keys have uniform length of 32 bytes or 64 nibbles.
  With the absence of 17th element, a `Branch Node` will never contains leaf value.
* When processing a `Branch Node` you need to emit the `hash to next elem` if the elem is not match for the current path nibble.
* When processing a `Leaf Node` or an `Extension Node` and you meet no match condition, you'll also emit a hash.


If you try to build witness on something else that is not an `Ethereum Account` and using keys with different length,
you will probably need to implement full spec from the Yellow Paper.

## Multi keys

Before we produce multiproof block witness, let us create a multi keys data structure that will help us doing nibbles comparison.

### Sort the keys lexicographically

For example, I have 16 keys. Before sort:

```text
e26f87f8d83b61dbd890cda95c46c74f8d22067c323a89b58e6e8f561f2fb8ea
5e00236babd8b0737512348d0a6bae0ed3e69e76391a8f16085c1c7a4864a098
28d0cacafa7c17f7a9b759289c11908f3ca0783fc1940399b8e8c216dcccab2d
a1ba56edb2cfcd4914d5bfc35965be5b7df3fc289f8c8c4f3987aaf58196119a
5021c9457544d81b9870ab986ba52a1fccedd35df09c66de268ecdf289e1127d
bac9405b4813ac28cc27bc09fb6b27aefa3e341d3ab7f91c63f2482446abb28b
d676c8ea429a4b2e075538475c4cc89cf0251335d167cac2bb516a6cd046fbfd
df3585baa4162db6431f36ea2d70380b855cdb53203c707463b5df2c4ed573dc
903b206fc2b1aed80eecc439e7ce5049e955b1d5e7b784aadf1c424c99bd270a
26eb8904b00d91adf989f5919b71e8bdf96ded347ee25f8cceeb32fb68fb396f
6a52cf44e5d529973c5f8c10e4a88301076065529370776136b08ddf28617634
6c4cb76d2205904095b8ac41e9deb533ced6d3f5cc5c4f5a55d6abd50b21d022
850169badff8c49045afcb92bddaa59bf0aa3bd996d5a9a2f19984659e0df156
1d86f4ba779b3e61f65cd0f1b4eea004ddb1cd42b6294979447579e57bb32e02
b63e59b25dc10e89b04f622ca45cd3da097e1ba41ff2fe202ca0587c53fdbe98
5b0f8a5612111ffbc215a7fb82ee382c1a36f0035653c1f3fa3f520c83bee256
```

After sort:
```
1d86f4ba779b3e61f65cd0f1b4eea004ddb1cd42b6294979447579e57bb32e02
26eb8904b00d91adf989f5919b71e8bdf96ded347ee25f8cceeb32fb68fb396f
28d0cacafa7c17f7a9b759289c11908f3ca0783fc1940399b8e8c216dcccab2d
5021c9457544d81b9870ab986ba52a1fccedd35df09c66de268ecdf289e1127d
5b0f8a5612111ffbc215a7fb82ee382c1a36f0035653c1f3fa3f520c83bee256
5e00236babd8b0737512348d0a6bae0ed3e69e76391a8f16085c1c7a4864a098
6a52cf44e5d529973c5f8c10e4a88301076065529370776136b08ddf28617634
6c4cb76d2205904095b8ac41e9deb533ced6d3f5cc5c4f5a55d6abd50b21d022
850169badff8c49045afcb92bddaa59bf0aa3bd996d5a9a2f19984659e0df156
903b206fc2b1aed80eecc439e7ce5049e955b1d5e7b784aadf1c424c99bd270a
a1ba56edb2cfcd4914d5bfc35965be5b7df3fc289f8c8c4f3987aaf58196119a
b63e59b25dc10e89b04f622ca45cd3da097e1ba41ff2fe202ca0587c53fdbe98
bac9405b4813ac28cc27bc09fb6b27aefa3e341d3ab7f91c63f2482446abb28b
d676c8ea429a4b2e075538475c4cc89cf0251335d167cac2bb516a6cd046fbfd
df3585baa4162db6431f36ea2d70380b855cdb53203c707463b5df2c4ed573dc
e26f87f8d83b61dbd890cda95c46c74f8d22067c323a89b58e6e8f561f2fb8ea
```

### A group

After you have nicely sorted keys, now is the time to make a parent group.
A `group` is a tuple of [first, last] act as index of keys.
A top level parent group will always have `first: 0` and `last: numkeys-1`
Besides sorting, we are not going to produce groups before the actual block witness take place.
We produce the top level group right before entering the block witness generation algorithm.
Top level group always start with `depth: 0`.

### Multi keys and Branch Node

During block witness construction, and you encounter a `Branch Node` you'll grouping the keys together
based on their prefix nibble. We only use a single nibble in this case. Therefore you'll probably end up with
16 groups of keys. __Each of the group consist of the same single nibble prefix__

Assume we are at `depth: 0`, the parent group is: `[0, 15]`, this is the result we have:

```
1d86f4ba779b3e61f65cd0f1b4eea004ddb1cd42b6294979447579e57bb32e02 # group 1: [0, 0]

26eb8904b00d91adf989f5919b71e8bdf96ded347ee25f8cceeb32fb68fb396f # group 2: [1, 2]
28d0cacafa7c17f7a9b759289c11908f3ca0783fc1940399b8e8c216dcccab2d

5021c9457544d81b9870ab986ba52a1fccedd35df09c66de268ecdf289e1127d # group 3: [3, 5]
5021b0f8a5612111ffbc215a7fb82ee382c1a36f0035653c1f3fa3f520c83bee
5e00236babd8b0737512348d0a6bae0ed3e69e76391a8f16085c1c7a4864a098

6a52cf44e5d529973c5f8c10e4a88301076065529370776136b08ddf28617634 # group 4: [6, 7]
6c4cb76d2205904095b8ac41e9deb533ced6d3f5cc5c4f5a55d6abd50b21d022

850169badff8c49045afcb92bddaa59bf0aa3bd996d5a9a2f19984659e0df156 # group 5: [8, 8]

903b206fc2b1aed80eecc439e7ce5049e955b1d5e7b784aadf1c424c99bd270a # group 6: [9, 9]

a1ba56edb2cfcd4914d5bfc35965be5b7df3fc289f8c8c4f3987aaf58196119a # group 7: [10, 10]

b63e59b25dc10e89b04f622ca45cd3da097e1ba41ff2fe202ca0587c53fdbe98 # group 8: [11, 12]
bac9405b4813ac28cc27bc09fb6b27aefa3e341d3ab7f91c63f2482446abb28b

d676c8ea429a4b2e075538475c4cc89cf0251335d167cac2bb516a6cd046fbfd # group 9: [13, 14]
df3585baa4162db6431f36ea2d70380b855cdb53203c707463b5df2c4ed573dc

e26f87f8d83b61dbd890cda95c46c74f8d22067c323a89b58e6e8f561f2fb8ea # group 10: [15, 15]
```

In a `Hexary Trie` you'll only match the current head(nibble) of the path with one elem from `Branch Node`.
In multiproof algorithm, you need to match every elem with as much groups as possible.
If there is no __invalid address__ or the invalid address hiding in one of the group, you will have
branches as much as non empty elements in a `Branch Node` and they will have the same nibble/prefix.

Because the match only involve one nibble, we advance the depth only one.

### Multi keys and Leaf Node and Extension Node

If you encounter a `Leaf Node` or `Extension Node`, they will have the same algorithm to generate groups.
For example, we are at `depth: 1`, and we are processing `group 3: [3, 5]`.
Using the prefix nibbles from `Leaf Node` or `Extension Node`, we produce two groups if our prefix nibbles is `021`:

```
5 021c9457544d81b9870ab986ba52a1fccedd35df09c66de268ecdf289e1127d # group 1: [3, 4]
5 021b0f8a5612111ffbc215a7fb82ee382c1a36f0035653c1f3fa3f520c83bee

5 e00236babd8b0737512348d0a6bae0ed3e69e76391a8f16085c1c7a4864a098 # group 2: [5, 5]
```

At max we will have 3 groups, and every possible combinations will be:

* match(1 group): all keys are matching the prefix nibbles.
* no match(1 group): there is no match.
* not match, match( 2 groups): a non matching group preceding matching group.
* match, not match(2 groups): a matching group before non matching group.
* not match, match, not match(3 groups): a matching group is between two non matching groups.

As you can see, we will only have a single match group or no match at all during constructing these groups.
And we only interested in this match group if it exist and ignore all other not matching groups.

#### A matching group for Extension Node

If we have a matching group for `Extension Node`, we will use this group as parent group
when we move deeper into the trie. We will advance our depth with the length of the prefix nibbles.

Let's say we have a match using nibbles `021`, the matching group is `group 1: [3, 4]`,
we can move deeper after `Extension Node` by adding 3 to our depth.

#### A matching group for Leaf Node

If we move deeper, finally we will encounter a `Leaf Node`.
If you have multiple keys inside your match group, then it is a bug in your multi keys algorithm.
If there is an __invalid address__ hiding in a matching group, you also have bug in your multi keys algorithm.
If you meet with a leaf group and a match group, emit an `Account` or a `Account Storage Leaf`.

```
5 021 c9457544d81b9870ab986ba52a1fccedd35df09c66de268ecdf289e1127d # group 1: [3, 3]

5 021 b0f8a5612111ffbc215a7fb82ee382c1a36f0035653c1f3fa3f520c83bee # group 2: [3, 4]
```

One of this group is a match for a `Leaf Node`, or no match at all.

### Emitting an `Account`

During emitting a `Leaf Node` or an `Account`, and the account have storage trie along with keys and values needs
to be included in the block witness too, we again repeat the algorithm in account storage mode and set the new depth to 0.
