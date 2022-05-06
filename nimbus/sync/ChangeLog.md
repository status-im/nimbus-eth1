# Collected change log from Jamie's snap branch squash merge

The comments are collected in chronological order, oldest first (as opposed to
squash merge order which is oldest last.)

## Sync: Rapidly find and track peer canonical heads

First component of new sync approach.

This module fetches and tracks the canonical chain head of each connected
peer.  (Or in future, each peer we care about; we won't poll them all so
often.)

This is for when we aren't sure of the block number of a peer's canonical
chain head.  Most of the time, after finding which block, it quietly polls
to track small updates to the "best" block number and hash of each peer.

But sometimes that can get out of step.  If there has been a deeper reorg
than our tracking window, or a burst of more than a few new blocks, network
delays, downtime, or the peer is itself syncing.  Perhaps we stopped Nimbus
and restarted a while later, e.g. suspending a laptop or Control-Z.  Then
this will catch up.  It is even possible that the best hash the peer gave us
in the `Status` handshake has disappeared by the time we query for the
corresponding block number, so we start at zero.

The steps here perform a robust and efficient O(log N) search to rapidly
converge on the new best block if it's moved out of the polling window no
matter where it starts, confirm the peer's canonical chain head boundary,
then track the peer's chain head in real-time by polling.  The method is
robust to peer state changes at any time.

The purpose is to:

- Help with finding a peer common chain prefix ("fast sync pivot") in a
  consistent, fast and explicit way.

- Catch up quickly after any long pauses of network downtime, program not
  running, or deep chain reorgs.

- Be able to display real-time peer states, so they are less mysterious.

- Tell the beam/snap/trie sync processes when to start and what blocks to
  fetch, and keep those fetchers in the head-adjacent window of the
  ever-changing chain.

- Help the sync process bootstrap usefully when we only have one peer,
  speculatively fetching and validating what data we can before we have more
  peers to corroborate the consensus.

- Help detect consensus failures in the network.

We cannot assume a peer's canonical chain stays the same or only gains new
blocks from one query to the next.  There can be reorgs, including deep
reorgs.  When a reorg happens, the best block number can decrease if the new
canonical chain is shorter than the old one, and the best block hash we
previously knew can become unavailable on the peer.  So we must detect when
the current best block disappears and be able to reduce block number.

 
## Config: Add `--new-sync` option and use it

This option enables new blockchain sync and real-time consensus algorithms that
will eventually replace the old, very limited sync.

New sync is work in progress.  It's included as an option rather than a code
branch, because it's more useful for testing this way, and must not conflict
anyway.  It's off by default.  Eventually this will become enabled by default
and the option will be removed.


## Tracing: New `traceGossips` category, tidy calls to other categories

 - `traceGossips` has been added, because on some networks there are so many
   transaction messages, it is difficult to see other activity.

 - Adds a trace macro corresponding to each of the packet tracing categories
   `traceTimeouts`, `traceNetworkErrors` and `tracePacketErrors`.  Improves
   readability of code using them, and API consistency.


## Sync: Move `tracePacket` etc into sync_types.nim

Move the templates `tracePacket`, `traceGossip` , `traceTimeout`,
`traceNetworkError` and `tracePacketError` from protocol_eth65 to
sync_types.

The reason for moving is they are also needed for `snap` protocol calls.


## Config: Add `--new-sync` option and use it

This option enables new blockchain sync and real-time consensus algorithms that
will eventually replace the old, very limited sync.

New sync is work in progress.  It's included as an option rather than a code
branch, because it's more useful for testing this way, and must not conflict
anyway.  It's off by default.  Eventually this will become enabled by default
and the option will be removed.


## Sync: Chain head: Promote peer chain head updates to debug level

This way, you can see peer chain head updates at `--log-level:DEBUG` without
being flooded by trace messages.

These occur about once every 15 seconds from each good peer.


## Sync: Chain head: Rate limit "blocked overlapping" error states

Under some conditions when a peer is not responding (but stays connected),
these messages happen continuously.  Don't output them and don't waste CPU
trying.


## Sync: Update protocol code to use `BlockHash`, `TxHash`, `NodeHash`

New hash type aliases added and used.  They're not `distinct` because that
would be disruptive, but perhaps they will be eventually, when code is
harmonised around using them.

Changes:

- Use `BlockHash` more consistently, to match the rest of the sync code.

- Use `BlockNumber` where currently `uint64` is used in the protocol (and
  `uint` was used before that, which was 32-bit on 32-bit targets).

- New alias `TxHash` is for transactions and is used in
  `NewPooledTransactionHashes` and `GetPooledTransactions`.

- New alias `NodeHash` is for trie nodes (or contract bytecode)
  and is used in `GetNodeData`.


## Sync: Set and update `syncStateRoot` for each peer

State syncing requires the `stateRoot` value of the selected block to sync to.

The chain head tracker selects a block and uses `block.stateRoot`.  State sync
reads that value to sync to.  It can change at any time, but that's ok, the
state sync algorithm is designed around that idea.

Aside from getting an initial `stateRoot`, the regular updates are essential
because state sync is so slow.

On Mainnet, it is normal for the initial selected block to become too old
before state sync is complete, and then peers stop providing data in their
replies.  The solution is for `stateRoot` to be updated by the chain head
tracker so it's always recent enough.  (On Goerli and a fast peer we can fetch
the whole state just in time without this.)

There are a number of issues with the simple implementation here:

- The selected `stateRoot` block shouldn't be the most recent canonical head,
  because it is prone to change due to small reorgs.  It should be a more stable
  block choice, slightly further back in time.

  However, any block close to the head is reasonably harmless during the state
  "snap" phase.  Small block differences cause a small state delta, which are
  patched automatically during "heal" traversals.

- During the state "heal" phase, `stateRoot` should not be updated on every
  block change, because it disrupts the "heal" traversal when this happens.

  It should be kept the same for longer, but not too long because the `snap/1`
  protocol does not provide state older than 128 blocks ago.

  So during "heal", `stateRoot` should be updated roughly every N blocks where
  N is close to 128, except when the heal is disrupted due to chain reorgs
  taking place or other loss of available state from the peer.

- During the state "heal" phase, `stateRoot` must be coordinated among all
  the peers.  This is because "heal" converges a patchwork of states from
  different times into a unified point-in-time whole state, so that execution
  can proceed using entirely local data from there.



## Sync: Add `genesisStateRoot` for state syncing

State syncing requires the `stateRoot` value of the selected block to sync to.
Normally the chain head tracker selects a block and uses `block.stateRoot`.

However, in some cases in test environments, the chain head tracker finds the
sync block is 0, the genesis block, without receiving that block from a peer.
Of course this only happens when connecting to peers that are on block 0
themselves, but it can happen and must be handled.

Perhaps we should not run state sync on block 0, and instead the local trie.
But to get the correct "flat" or "snap sync" style representation that requires
special code.

In order to exercise the state sync code and see how peers behave when block 0
is selected, and avoid special code, use the genesis `stateRoot` found locally,
and sync that state from peers like any other.



## Sync: New types `LeafPath`, `InteriorPath` and support functions

`InteriorPath` is a path to an interior node in an Ethereum hexary trie.  This
is a sequence of 0 to 64 hex digits.  0 digits means the root node, and 64
digits means a leaf node whose path hasn't been converted to `LeafPath` yet.

`LeafPath` is a path to a leaf in an Ethereum hexary trie.  Individually, each
leaf path is a hash, but rather than being the hash of the contents, it's the
hash of the item's address.  Collectively, these hashes have some 256-bit
numerical properties: ordering, intervals and meaningful difference.


## Sync: Add `onGetNodeData`, `onNodeData` to `eth/65` protocol handler

These hooks allow new sync code to register to provide reply data or consume
incoming events without a circular import dependency involving `p2pProtocol`.

Without the hooks, the protocol file needs to import functions that consume
incoming network messages so the `p2pProtocol` can call them, and the functions
that produce outgoing network messages need to import the protocol file.

But related producer/consumer function pairs are typically located in the same
file because they are closely related.  For example the producer of
`GetNodeData` and the consumer of `NodeData`.

In this specific case, we also need to break the `requestResponse` relationship
between `GetNodeData` and `NodeData` messages when pipelining.

There are other ways to accomplish this, but this way is most practical, and
it allows different protocol-using modules to coexist easily.  When the hooks
aren't set, default behaviour is fine.


## Sync: Robust support for `GetNodeData` network calls

This module provides an async function to call `GetNodeData`, a request in
the Ethereum DevP2P/ETH network protocol.  Parallel requests can be issued,
maintaining a pipeline.

Given a list of hashes, it returns a list of trie nodes or contract
bytecodes matching those hashes.  The returned nodes may be any subset of
those requested, including an empty list.  The returned nodes are not
necessarily in the same order as the request, so a mapping from request
items to node items is included.  On timeout or error, `nil` is returned.

Only data passing hash verification is returned, so hashes don't need to be
verified again.  No exceptions are raised, and no detail is returned about
timeouts or errors, but systematically formatted trace messages are output
if enabled, and show in detail if various events occur such as timeouts,
bad hashes, mixed replies, network errors, etc.

This tracks queued requests and individual request hashes, verifies received
node data hashes, and matches them against requests.  When a peer replies in
same order as requests are sent, and each reply contains nodes in the same
order as requested, the matching process is efficient.  It avoids storing
request details in a hash table when possible.  If replies or nodes are out
of order, the process is still efficient but has to do a little more work.

Empty replies:

Empty replies are matched with requests using a queue draining technique.
After an empty reply is received, we temporarily pause further requests and
wait for more replies.  After we receive all outstanding replies, we know
which requests the empty replies were for, and can complete those requests.

Eth/66 protocol:

Although Eth/66 simplifies by matching replies to requests, replies can still
have data out of order or missing, so hashes still need to be verified and
looked up.  Much of the code here is still required for Eth/66.

References:

- [Ethereum Wire Protocol (ETH)](https://github.com/ethereum/devp2p/blob/master/caps/eth.md)
- [`GetNodeData` (0x0d)](https://github.com/ethereum/devp2p/blob/master/caps/eth.md#getnodedata-0x0d)
- [`NodeData` (0x0e)](https://github.com/ethereum/devp2p/blob/master/caps/eth.md#nodedata-0x0e)


## Sync: Robustly parse trie nodes from network untrusted data

This module parses hexary trie nodes as used by Ethereum from data received
over the network.  The data is untrusted, and a non-canonical RLP encoding
of the node must be rejected, so it is parsed carefully.

The caller provides bytes and context.  Context includes node hash, trie
path, and a boolean saying if this trie node is child of an extension node.

The result of parsing is up to 16 child node hashes to follow, or up to 7
leaf nodes to decode.

The caller should ensure the bytes are verified against the hash before
calling this parser.  Even though they pass the hash, they are still
untrusted bytes that must be parsed carefully, because the hash itself is
from an untrusted source.

`RlpError` exceptions may occur on some well-crafted adversarial input
due to the RLP reader implementation.  They could be trapped and treated
like other parse errors, but they are not, to avoid the overhead of
`try..except` in the parser (which uses C `setjmp`).  The caller should
put `try..except RlpError` outside its trie node parsing loop.


### Path range metadata benefits

Because data is handled in path ranges, this allows a compact metadata
representation of what data is stored locally and what isn't, compared with
the size of a representation of partially completed trie traversal with
`eth` `GetNodeData`.  Due to the smaller metadata, after aborting a partial
sync and restarting, it is possible to resume quickly, without waiting for
the very slow local database scan associated with older versions of Geth.

However, Nimbus's sync method uses this principle as inspiration to
obtain similar metadata benefits whichever network protocol is used.


### Distributed hash table (DHT) building block

Although `snap` was designed for bootstrapping clients with the entire
Ethereum state, it is well suited to fetching only a subset of path ranges.
This may be useful for bootstrapping distributed hash tables (DHTs).


### Remote state and Beam sync benefits

`snap` was not intended for Beam sync, or "remote state on demand", used by
transactions executing locally that fetch state from the network instead of
local storage.

Even so, as a lucky accident `snap` allows individual states to be fetched
in fewer network round trips than `eth`.  Often a single round trip,
compared with about 10 round trips per account query over `eth`.  This is
because `eth` `GetNodeData` requires a trie traversal chasing hashes
sequentially, while `snap` `GetTrieNode` trie traversal can be done with
predictable paths.

Therefore `snap` can be used to accelerate remote states and Beam sync.


### Performance benefits

`snap` is used for much higher performance transfer of the entire Ethereum
execution state (accounts, storage, bytecode) compared with hexary trie
traversal using `eth` `GetNodeData`.

It improves both network and local storage performance.  The benefits are
substantial, and summarised here:

- [Ethereum Snapshot Protocol (SNAP) - Expected results]
  (https://github.com/ethereum/devp2p/blob/master/caps/snap.md)
- [Geth v1.10.0 - Snap sync]
  (https://blog.ethereum.org/2021/03/03/geth-v1-10-0/#snap-sync)

In the Snap sync model, local storage benefits require clients to adopt a
different representation of Ethereum state than the trie storage that Geth
(and most clients) traditionally used, and still do in archive mode,

However, Nimbus's sync method obtains similar local storage benefits
whichever network protocol is used.  Nimbus uses `snap` protocol because
it is a more efficient network protocol.


## Sync: Changes to `snap/1` protocol to match Geth parameters

The `snap/1` specification doesn't match reality.  If we implement the
protocol as specified, Geth drops the peer connection.  We must do as Geth
expects.

- `GetAccountRanges` and `GetStorageRanges` take parameters `origin` and
  `limit`, instead of a single `startingHash` parameter in the
  specification.  `origin` and `limit` are 256-bit paths representing the
  starting hash and ending trie path, both inclusive.

- If the `snap/1` specification is followed (omitting `limit`), Geth 1.10
  disconnects immediately so we must follow this deviation.

- Results from either call may include one item with path `>= limit`.  Geth
  fetches data from its internal database until it reaches this condition or
  the bytes threshold, then replies with what it fetched.  Usually there is
  no item at the exact path `limit`, so there is one after.

## Sync: Ethereum Snapshot Protocol (SNAP), version 1

This patch adds the `snap/1` protocol, documented at:

- [Ethereum Snapshot Protocol (SNAP)]
  (https://github.com/ethereum/devp2p/blob/master/caps/snap.md).

This is just the protocol handlers, not the sync algorithm.


## Sync: Changes to `snap/1` protocol to match Geth `GetStorageRanges`

The main part of this part is to add a comment documenting quirky behaviour of
`GetStorageRanges` with Geth, and workarounds for the missing right-side proof.

The code change is smaller, but it does change the type of parameters `origin`
and limit` to `GetStorageRanges`.  Trace messages are updated accordingly.

When calling a Geth peer with `GetStorageRanges`:
 - Parameters `origin` and `limit` may each be empty blobs, which mean "all
   zeros" (0x00000...) or "no limit" (0xfffff...)  respectively.

   (Blobs shorter than 32 bytes can also be given, and they are extended with
   zero bytes; longer than 32 bytes can be given and are truncated, but this
   is Geth being too accepting, and shouldn't be used.)

 - In the `slots` reply, the last account's storage list may be empty even if
   that account has non-empty storage.

   This happens when the bytes threshold is reached just after finishing
   storage for the previous account, or when `origin` is greater than the
   first account's last storage slot.  When either of these happens, `proof`
   is non-empty.  In the case of `origin` zero or empty, the non-empty proof
   only contains the left-side boundary proof, because it meets the condition
   for omitting the right-side proof described in the next point.

 - In the `proof` reply, the right-side boundary proof is only included if
   the last returned storage slot has non-zero path and `origin != 0`, or if
   the result stops due to reaching the bytes threshold.

   Because there's only one proof anyway if left-side and right-side are the
   same path, this works out to mean the right-side proof is omitted in cases
   where `origin == 0` and the result stops at a slot `>= limit` before
   reaching the bytes threshold.

   Although the specification doesn't say anything about `limit`, this is
   against the spirit of the specification rule, which says the right-side
   proof is always included if the last returned path differs from the
   starting hash.

   The omitted right-side proof can cause problems when using `limit`.
   In other words, when doing range queries, or merging results from
   pipelining where different `stateRoot` hashes are used as time progresses.
   Workarounds:

   - Fetch the proof using a second `GetStorageRanges` query with non-zero
	 `origin` (perhaps equal to `limit`; use `origin = 1` if `limit == 0`).

   - Avoid the condition by using `origin >= 1` when using `limit`.

   - Use trie node traversal (`snap` `GetTrieNodes` or `eth` `GetNodeData`)
	 to obtain the omitted proof.

 - When multiple accounts are requested with `origin > 0`, only one account's
   storage is returned.  There is no point requesting multiple accounts with
   `origin > 0`.  (It might be useful if it treated `origin` as applying to
   only the first account, but it doesn't.)

 - When multiple accounts are requested with non-default `limit` and
   `origin == 0`, and the first account result stops at a slot `>= limit`
   before reaching the bytes threshold, storage for the other accounts in the
   request are returned as well.  The other accounts are not limited by
   `limit`, only the bytes threshold.  The right-side proof is omitted from
   `proof` when this happens, because this is the same condition as described
   earlier for omitting the right-side proof.  (It might be useful if it
   treated `origin` as applying to only the first account and `limit` to only
   the last account, but it doesn't.)
