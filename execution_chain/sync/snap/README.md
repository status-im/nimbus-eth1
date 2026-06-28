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
2. Fully verify downloaded data from stage 1. and assemble partial MPTs
3. TBD: Download the missing data for stage 2.
4. TBD: Verify downloaded data from statge 3. and complete MPTs to provide a
   complete state.

### ad 1.

For managing download, a recent *state* must be maintained where the downloaded
data refer to. *States* are identified by a *state root* hash value.

The challenge is that a *state* must always be recent which implies that they
are available only for a short time window. Officially, this time window is
implied by the latest 128 blocks of the (ever changing) block chain, in
practice it varies a bit. Outside this time window, download peers may and will
reject providing data.

#### Managing States for Downloading

Download *states* are cached. Whenever a new peer enters the system, the last
finalised *state* from the CL is added to the cache and is also remembered by
the peer as its favourable *state*. If the cache reached its maximal fill size,
one state has to be removed from the cache. Downloaded data will still be
available in *archives* mode *on disk* (i.e. persistently stored.).

If the most idle *state* in the cache (.i.e no data downloaded for a while) is
larger than a threshold (30 minutes say), then it is removed. Otherwise, if
there is a *state* with no data downloaded, the oldest such *state* (i.e. least
associated block number) is removed. Otherwise, If the most idle *state* in
the cache is removed.

#### Managing Peers for Downloading

Data requested from a peer are organised by the download *states* in the
following order.

* Download for the favourable *state*
* Download for the last finalised CL state (if it differs from above)
* Download for for other *state*, the ones with most downloaded data first

Downloading takes place until the peer gets exhausted, i.e. if *states*
fall out of the window of supported states. Consequently, the favourable
*state* of a peer might be updated.

#### Managing Data for Downloading

Downloaded data are stored on disk immediately without full verification
while the details of the downloaded data are also kept in the *state* cache.
For all cached *states*, downloading ranges are synchronised in an interleaved
way, so that these ranges do not overlap unless unavoidable.

This allows to merge data from adjacent *states* (with small block number
differences) to pivot state MPT where the adjacent *state* has only small
changes relative to the pivot MPT.

### ad 2.

The assembly algorithm of the partial MPT works as follows.

* Find a pivot state which has maximal accounts coverage.
* Process states by increasing height (i.e. block number)  distance from the
  pivot state.
  + While processing, maintain a list of dangling links of the pivot
    *state* MPT.
  + If a data package with a different state resolves some dangling links,
    then merge it and update the list of dangling links, afterwards.

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

| *Variable*                           | *Logic type*    | *Short description*     |
|:-------------------------------------|:---------------:|:------------------------|
|                                      |                 |                         |
| nec_snap_accumulated_states_coverage | factor of 2^256 | active account ranges   |
| nec_snap_archived_states_coverage    | factor of 2^256 | archived account ranges |
| nec_snap_active_states               | number          | number of active states |
| nec_snap_merged_mpt_coverage         | factor of 2^256 | MPT bulder completeness |

###  Graphana example

See chapter *Graphana example* of [beacon/README](../beacon/README.md)
