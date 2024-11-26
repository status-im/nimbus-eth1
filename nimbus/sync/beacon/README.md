Beacon Sync
===========

Some definition of terms, and a suggestion of how a beacon sync can be encoded
providing pseudo code is provided by
[Beacon Sync](https://notes.status.im/nimbus-merge-first-el?both=#Beacon-sync).

In the following, the data domain the Beacon Sync acts upon is explored and
presented. This leads to an implementation description without the help of
pseudo code but rather provides a definition of the sync and domain state
at critical moments.

For handling block chain imports and related actions, abstraction methods
from the `forked_chain` module will be used (abbreviated **FC**.) The **FC**
entities **base** and **latest** from this module are always printed **bold**.


Sync Logic Outline
------------------

Here is a simplification of the sync process intended to provide a mental
outline of how it works.

In the following block chain layouts, a left position always stands for an
ancestor of a right one.

        0------C1                                                            (1)

        0--------L1                                                          (2)
                 \_______H1

        0------------------C2                                                (3)

        0--------------------L2                                              (4)
                            \________H2

where

* *0* is genesis
* *C1*, *C2* are the *latest* (aka cursor) entities from the **FC** module
* *L1*, *L2*, are updated *latest* entities from the **FC** module
* *H1*, *H2* are block headers (or blocks) that are used as sync targets

At stage *(1)*, there is a chain of imported blocks *[0,C1]* (written as
compact interval of block numbers.)

At stage *(2)*, there is a sync request to advance up until block *H1* which
is then fetched from the network along with its ancestors way back until there
is an ancestor within the chain of imported blocks *[0,L1]*. The chain *[0,L1]*
is what the *[0,C1]* has morphed into when the chain of blocks ending at *H1*
finds its ancestor.

At stage *(3)* all blocks recently fetched have now been imported via **FC**.
In addition to that, there might have been additional imports from other
entities (e.g. `newPayload`) which has advanced *H1* further to *C2*.

Stage *(3)* has become similar to stage *(1)* with *C1* renamed as *C2*, ditto
for the symbols *L2* and *H2* for stage *(4)*.


Implementation, The Gory Details
--------------------------------

### Description of Sync State

The following diagram depicts a most general state view of the sync and the
*FC* modules and at a given point of time

        0         B          L                                               (5)
        o---------o----------o
        | <--- imported ---> |
                     C                     D                H
                     o---------------------o----------------o
                     | <-- unprocessed --> | <-- linked --> |

where

* *B* -- **base**, current value of this entity (with the same name) of the
         **FC** module (i.e. the current value when looked up.)

* *C* -- coupler, parent of the left endpoint of the chain of headers or blocks
         to be fetched and imported. The block number of *C* is somewhere
		 between the ones of *B* and *C* inclusive.

* *L* -- **latest**, current value of this entity (with the same name) of the
         **FC** module (i.e. the current value when looked up.) *L* need not
         be a parent of any header of the linked chain `(C,H]` (see below for
         notation). Both *L* and *H* might be heads of different forked chains.

* *D* -- dangling, header with the least block number of the linked chain in
         progress ending at *H*. This variable is used to record the download
         state eventually reaching *Y* (for notation *D<<H* see clause *(6)*
         below.)

* *H* -- head, sync target header which typically was the value of a *sync to
         new head* request (via RPC)

The internal sync state (as opposed to the general state also including the
state of **FC**) is defined by the triple *(C,D,H)*. Other parameters like *L*
mentioned in *(5)* are considered ephemeral to the sync state. They are always
seen by its latest values and not cached by the syncer.

There are two order releations and some derivatives used to describe relations
between headers or blocks.

        For blocks or headers A and B, A is said less or equal B if the      (6)
        block numbers are less or equal. Notation: A <= B.

        The notation A ~ B stands for A <= B <= A which makes <= an order
        relation (relative to ~ rather than ==). If A ~ B does not hold
        then the notation A !~ B is used.

        The notation A < B stands for A <= B and A !~ B.

        The notation B-1 stands for any block or header with block number of
        B less one.


        For blocks or headers A and B, writing A <- B stands for the block
        A be parent of B (there can only be one parent of B.)

        For blocks or headers A and B, A is said ancestor of, or equal to B
        if A == B or there is a non-empty parent lineage A <- X <- Y <-..<- B.
        Notation: A << B (note that << is an equivalence relation.)

        The compact interval notation [A,B] stands for the set {X|A<<X<<B}
        and the half open interval notation stands for [A,B]-{A} (i.e. the
        interval without the left end point.)

Note that *A<<B* implies *A<=B*. Boundary conditions that hold for the
clause *(5)* diagram are

        there is a Z in [0,L] with C ~ Z, D is in [C,H]                      (7)


### Sync Processing

Sync starts at an idle state

        0                 H  L                                               (8)
        o-----------------o--o
        | <--- imported ---> |

where *H<=L* (*H* needs only be known by its block number.) The state
parameters *C* and *D* are irrelevant here.

Following, there will be a request to advance *H* to a new position as
indicated in the diagram below

        0            B                                                       (9)
        o------------o-------o
        | <--- imported ---> |                              D
                     C                                      H
                     o--------------------------------------o
                     | <----------- unprocessed ----------> |

with a new sync state *(C,H,H)*. The parameter *B* is the **base** entity
of the **FC** module. The parameter *C* is a placeholder with *C ~ B*. The
parameter *D* is set to the download start position *H*.

The syncer then fetches the header chain *(C,H]* from the network. While
iteratively fetching headers, the syncer state *(C,D,H)* will only change on
its second position *D* time after a new header was fetched.

Having finished downloading then *C~D-1*. The sync state is *(D-1,D,H)*. One
will end up with a situation like

        0               Y    L                                              (10)
        o---------------o----o
        | <--- imported ---> |
                     C    Z                                 H
                     o----o---------------------------------o
                     | <-------------- linked ------------> |

for some *Y* in *[0,L]* and *Z* in *(C,H]* where *Y<<Z* with *L* the **latest**
entity of the **FC** logic.

If there are no such *Y* and *Z*, then *(C,H]* is discarded and sync processing
restarts at clause *(8)* by resetting the sync state (e.g. to *(0,0,0)*.)

Otherwise choose *Y* and *Z* with maximal block number of *Y* so that *Y<-Z*.
Then complete *(Y,H]==[Z,H]* to a lineage of blocks by downloading missing
block bodies.

Having finished with block bodies, the sync state will be expressed as
*(Y,Y,H)*. With the choice of the first two entries equal it is indicated that
the lineage *(Y,H]* is fully populated with blocks.

        0               Y                                                   (11)
        o---------------o----o
        | <--- imported ---> |
                        Y                                   H
                        o-----------------------------------o
                        | <------------ blocks -----------> |

The blocks *(Y,H]* will then be imported and executed. While this happens, the
internal state of the **FC** might change/reset so that further import becomes
impossible. Even when starting import, the block *Y* might not be in *[0,L]*
anymore due to some internal reset of the **FC** logic. In any of those
cases, sync processing restarts at clause *(8)* by resetting the sync state.

In case all blocks can be imported, one will will end up at

        0                 Y                                 H   L           (12)
        o-----------------o---------------------------------o---o
        | <--- imported --------------------------------------> |

with *H<<L* for *L* the current value of the **latest** entity of the **FC**
module.

In many cases, *H==L* but there are other actors which also might import blocks
quickly after finishing import of *H* before formally committing this task. So
*H* can become ancestor of *L*.

Now clause *(12)* is equivalent to clause *(8)*.


Running the sync process for *MainNet*
--------------------------------------

For syncing, a beacon node is needed that regularly informs via *RPC* of a
recently finalised block header.

The beacon node program used here is the *nimbus_beacon_node* binary from the
*nimbus-eth2* project (any other, e.g.the *light client*  will do.)
*Nimbus_beacon_node* is started as

      ./run-mainnet-beacon-node.sh \
         --web3-url=http://127.0.0.1:8551 \
         --jwt-secret=/tmp/jwtsecret

where *http://127.0.0.1:8551* is the URL of the sync process that receives the
finalised block header (here on the same physical machine) and `/tmp/jwtsecret`
is the shared secret file needed for mutual communication authentication.

It will take a while for *nimbus_beacon_node* to catch up (see the
[Nimbus Guide](https://nimbus.guide/quick-start.html) for details.)

### Starting `nimbus` for syncing

As the syncing process is quite slow, it makes sense to pre-load the database
from an *Era1* archive (if available) before starting the real sync process.
The command for importing an *Era1* reproitory would be something like

       ./build/nimbus_execution_client import \
          --era1-dir:/path/to/main-era1/repo \
          ...

which will take its time for the full *MainNet* Era1 repository (but way faster
than the beacon sync.)

On a system with memory considerably larger than *8GiB* the *nimbus* binary is
started on the same machine where the beacon node runs with the command


       ./build/nimbus_execution_client \
          --network=mainnet \
          --engine-api=true \
          --engine-api-port=8551 \
          --engine-api-ws=true \
          --jwt-secret=/tmp/jwtsecret \
          ...

Note that *--engine-api-port=8551* and *--jwt-secret=/tmp/jwtsecret* match
the corresponding options from the *nimbus-eth2* beacon source example.

### Syncing on a low memory machine

On a system with memory with *8GiB* the following additional options proved
useful for *nimbus* to reduce the memory footprint.

For the *Era1* pre-load (if any) the following extra options apply to
"*nimbus import*":

       --chunk-size=1024
       --debug-rocksdb-row-cache-size=512000
       --debug-rocksdb-block-cache-size=1500000

To start syncing, the following additional options apply to *nimbus*:

       --debug-beacon-chunk-size=384
       --debug-rocksdb-max-open-files=384
       --debug-rocksdb-write-buffer-size=50331648
       --debug-rocksdb-block-cache-size=1073741824
       --debug-rdb-key-cache-size=67108864
       --debug-rdb-vtx-cache-size=268435456

Also, to reduce the backlog for *nimbus-eth2* stored on disk, the following
changes might be considered. In the file
*nimbus-eth2/vendor/mainnet/metadata/config.yaml* change the folloing
settings

       MIN_EPOCHS_FOR_BLOCK_REQUESTS: 33024
       MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS: 4096
to

       MIN_EPOCHS_FOR_BLOCK_REQUESTS: 8
       MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS: 8

Caveat: These changes are not useful when running *nimbus_beacon_node* as a
production system.

Metrics
-------

The following metrics are defined in *worker/update/metrics.nim* which will
be available if *nimbus* is compiled with the additional make flags
*NIMFLAGS="-d:metrics \-\-threads:on"*:

| *Variable*         | *Logic type* | *Short description* |
|:-------------------|:------------:|:--------------------|
|                    |              |                     |
| beacon_base        | block height | **B**, *increasing* |
| beacon_latest      | block height | **L**, *increasing* |
| beacon_coupler     | block height | **C**, *increasing* |
| beacon_dangling    | block height | **D**               |
| beacon_head        | block height | **H**, *increasing* |
| beacon_target      | block height | **T**, *increasing* |
|                            |      |                     |
| beacon_header_lists_staged | size | # of staged header list records      |
| beacon_headers_unprocessed | size | # of accumulated header block numbers|
| beacon_block_lists_staged  | size | # of staged block list records       |
| beacon_blocks_unprocessed  | size | # of accumulated body block numbers  |
|                            |      |                                      |
| beacon_buddies             | size | # of peers working concurrently      |
