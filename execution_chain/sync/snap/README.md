Snap Sync
=========

The idea behind the snap sync mecanism is ro download the leaves of an MPT
(i.e. Merkle Patricia Trie) and re-assemble it locally. There are three types
of data to be downloaded:

* Accounts for a particular state (i.e. snapshot of a point iin time)
* Storage slots for a particular account (for a particular state)
* Code data for a particular account (for a particular state)

While the first two items refer to an MPT, tha last item refers to a simple
unstructured piece of data.

Implemented Algorithm
---------------------

The general algorithm looks like

1. Download data via *snap* ptotocol and cache it
2. Verify downloaded data from statge 1. and assemble partial MPTs
3. Download the missing data for stage 2.
4. Verify downloaded data from statge 3. and complete MPTs to provide a complete state.

### ad 1.

For managing download, a recent *state* must be maintained where the downloaded
data refer to. *States* are identigied by a *state root* hash value.

The challenge is that a *state* must always be recent which implies that they
are available only for a short time window. Officially, this time window is
implied by the latest 128 blocks of the (ever chanhing) block chain, in
practice it varies a bit. Outside this time window, download peers may and will
reject providing data.

#### Managing States for Downloading

Download *states* are cached. Whenever a new peer enters the system, the last
finalised *state* from the CL is added to the cache and is also remembered by
the peer as its favourable *state*. If the cache becomes full, one state has
to be removed from the cache.

If the most idle *state* in the cache (.i.e no data downloaded for a while) is
larger than a threshold (30 minutes say), then it is removed. Otherwise, if
there is a *state* with no data downloaded, the oldest such *state* (i.e. least
associated block number) is removed. Otherwise, If the most idle *state* in
the cache is removed.

#### Managing Peers for Downloading

As mentioned above, a download peer keeps track of a favourable *state* which
is the one registered when staring download. It also keeps track of the block
number of the latest rejected *state* (i.e. out of the time window.)

A peer will then download *states* data in the following order

* Download for the *state* that has already the most downloaded (accled *pivot*).
* Download for its own the favourable *state*
* Download for for other *state*, most downloaded aleady first

avoiding *states* with associated block numbers not exceeding the tracked block
number of the latest rejected *state*. This block number and the favourable
*state* are updated when needed (i.e. according to changing the time window.)

#### Managing Data for Downloading

Downloaded data are stored on disk immediately without verification while
the details of the downloaded data are also kept in the *state* cache. For
all cached *states*, downloading ranges are synchronised in an interleaved
way, so that these ranges do not overlap unless unavoidable. As the account
differences are assumed to be small between adjacent *states*, it is expected
that these *state* can *borrow* parts when assembling MPTs.

### ad 2.

TBD

### ad 3.

TBD

### ad 4.

TBD

Project Status
--------------

* Raw data download and storage is implemented
* Previous download session can be resumed

TODO

* verify byte code

Metrics
-------

| *Variable*                      | *Logic type* | *Short description*        |
|:--------------------------------|:------------:|:---------------------------|
|                                 |              |                            |
| nec_snap_max_acc_state_coverage | hash range   | pivot range coverage       |
| nec_snap_acc_coverage           | hash range   | accumulated range coverage |
|                                 |              |                            |

###  Graphana example

See chapter *Graphana example* of [beacon/README](../beacon/README.md)

Test runner
-----------

Currently, the snap syncer can only be started from the sync tracer which
is part of a *Draft PR* on github.

### Download and compiling the sync tracer

For the tracer, use the latest [Beacon sync trace..](https://github.com/status-im/nimbus-eth1/pulls?q=is%3Apr+is%3Aopen+Beacon+sync+trace) draft PR. Then rebase to the *master* (or any other branch.) Compile it with

       make syncer_test_client_trace

### Running a test

Start the tracer with

       ./build/syncer_test_client_trace \
	       --debug-snap-sync ..<nimbus-options>.. \
		   [-- ..<tracer-options>..]

where *&lt;nimbus-options&gt;* can be listed with

       ./build/nimbus_execution_client --help

and *&lt;tracer-options&gt;* can be listed with

       ./build/syncer_test_client_trace --help

An example for running on *hoodi* would be

        ./build/syncer_test_client_trace \
		   --network=hoodi --debug-snap-sync --log-level:TRACE \
		   -- --snap-sync-resume

where the option *--snap-sync-resume* will cause the tracer resuming the
previous download session (if there was any.)
