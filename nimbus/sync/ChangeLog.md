# Collected change log from Jamie's snap branch squash merge

The comments are collected in chronological order, oldest first (as opposed to
squash merge order which is oldest last.)

If a similar comment is found in a source file it was deleted here.


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
