Syncing
=======

Syncing blocks is performed in two partially overlapping phases

* loading the header chains into separate database tables
* removing headers from the headers chain, fetching the rest of the
  block the header belongs to and executing it

Header chains
-------------

The header chains are the triple of

* a consecutively linked chain of headers starting starting at Genesis
* followed by a sequence of missing headers
* followed by a consecutively linked chain of headers ending up at a
  finalised block header received from the consensus layer

A sequence *@[h(1),h(2),..]* of block headers is called a consecutively
linked chain if

* block numbers join without gaps, i.e. *h(n).number+1 == h(n+1).number*
* parent hashes match, i.e. *h(n).hash == h(n+1).parentHash*

General header chains layout diagram

      G                B                     L                F              (1)
      o----------------o---------------------o----------------o--->
      | <-- linked --> | <-- unprocessed --> | <-- linked --> |

Here, the single upper letter symbols *G*, *B*, *L*, *F* denote block numbers.
For convenience, these letters are also identified with its associated block
header or the full block. Saying *"the header G"* is short for *"the header
with block number G"*.

Meaning of *G*, *B*, *L*, *F*:

* *G* -- Genesis block number *#0*
* *B* -- base, maximal block number of linked chain starting at *G*
* *L* -- least, minimal block number of linked chain ending at *F* with *B <= L*
* *F* -- final, some finalised block

This definition implies *G <= B <= L <= F* and the header chains can uniquely
be described by the triple of block numbers *(B,L,F)*.

Storage of header chains:
-------------------------

Some block numbers from the set *{w|G<=w<=B}* may correspond to finalised
blocks which may be stored anywhere. If some block numbers do not correspond
to finalised blocks, then the headers must reside in the *flareHeader*
database table. Of course, due to being finalised such block numbers constitute
a sub-chain starting at *G*.

The block numbers from the set *{w|L<=w<=F}* must reside in the *flareHeader*
database table. They do not correspond to finalised blocks.

Header chains initialisation:
-----------------------------

Minimal layout on a pristine system

      G                                                                      (2)
      B
      L
      F
      o--->

When first initialised, the header chains are set to *(G,G,G)*.

Updating header chains:
-----------------------

A header chain with an non empty open interval *(B,L)* can be updated only by
increasing *B* or decreasing *L* by adding headers so that the linked chain
condition is not violated.

Only when the open interval *(B,L)* vanishes the right end *F* can be increased
by *Z* say. Then

* *B==L* beacuse interval *(B,L)* is empty
* *B==F* because *B* is maximal

and the header chains *(F,F,F)* (depicted in *(3)*) can be set to *(B,Z,Z)*
(as depicted in *(4)*.)

Layout before updating of *F*

                       B                                                     (3)
                       L
      G                F                     Z
      o----------------o---------------------o---->
      | <-- linked --> |

New layout with *Z*

                                             L'                              (4)
      G                B                     F'
      o----------------o---------------------o---->
      | <-- linked --> | <-- unprocessed --> |

with *L'=Z* and *F'=Z*.

Note that diagram *(3)* is a generalisation of *(2)*.


Complete header chain:
----------------------

The header chain is *relatively complete* if it satisfies clause *(3)* above
for *G < B*. It is *fully complete* if *F==Z*. It should be obvious that the
latter condition is temporary only on a live system (as *Z* is permanently
updated.)

If a *relatively complete* header chain is reached for the first time, the
execution layer can start running an importer in the background compiling
or executing blocks (starting from block number *#1*.) So the ledger database
state will be updated incrementally.
