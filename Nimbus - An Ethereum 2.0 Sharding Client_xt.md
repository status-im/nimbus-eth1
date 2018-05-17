
## Nimbus - An Ethereum 2.0 Sharding Client  


# OVERVIEW

Nimbus aims to be a Sharding client implementation for the Ethereum Public Blockchain. Nimbus will be designed to perform well on resource-restricted devices, focus on a production-ready implementation of Web3 and will be supported and maintained to deliver on all of Ethereum 2.0’s goals.

# GOALS

1.  Create an Ethereum Implementation suitable for Resource-Restricted Devices.

2.  Create an Implementation team for [Ethereum Research](http://ethereumresearch.org/)’s (aka Ethereum Asia Pacific Limited) [Applied Research Objectives](https://hackmd.io/s/HkLkj55yb#objectives-in-applied-research), with a focus on:
	a. Proof-of-Stake
   	b. Sharding
   	c. Stateless Clients
   	d. LES2 (?)
   	e.  eWASM

3.  Close the Gap between Research Modeling and Production.

4.  Pledge to participate, implement and conform to the EIP process.

5.  Permissive Licensing.

6.  Focus on Production-ready Web 3.0 Stack (Whisper, PSS and Swarm) and it’s continued research & development.

7.  Marketing & promotion to address community concerns on scalability and bolster Ethereum’s dominant mindshare.


# REQUIREMENTS

## Nim

[Nim](https://nim-lang.org/) is a productive, general purpose systems programming language with a Python-like syntax that compiles to C. Using Nim allows us to rapidly implement Ethereum and allows us to take advantage of mature C tooling in both compilation of machine code and static code analysis.



With Ethereum research currently being modeled in Python, the end result should be code that is both easy for us to bring research into production, a high degree of code reasonability for researchers, as well as being performant for production.



In addition to this the core contributors and Nim community have been very supportive and enthusiastic about support for the project.


For more information please read [https://nim-lang.org/](https://nim-lang.org/)

## Development on Embedded Systems

We believe that the largest successful deployment of Ethereum will reside on embedded systems, specifically mobile personal computing (Smartphones) and IoT devices.


Existing implementations of Ethereum have been focused on Desktops and Servers, while necessary for the initial success of Ethereum and being suitable for full & archival nodes, their deployment onto embedded systems has been an after-thought. Through the development of Status we have found the dominant Ethereum implementations, Geth and Parity are not suitable candidates for our target platform without profiling and optimisation (in progress).



While archival nodes with Nimbus will be supported, Nimbus will be developed as a light client first implementation with a focus on Proof-of-Stake and Sharding.



Through the deployment of Status among 40,000 alpha testers, a significant portion (23.6%) of users still run on old mobile devices. We propose a self-imposed constraint, a requirement to build and run on 2014 SoC architectures, the Cortex-A53 (Samsung Note 4 & [Raspberry Pi 3](https://www.raspberrypi.org/products/raspberry-pi-3-model-b/)), the Apple A8 (iPhone 6) as well as MIPS-based architectures, such as the [Onion Omega2](https://onion.io/omega2/). Given the recent Spectre vulnerabilities open processors such as RISC-V should see an increase in demand and we should support them.



With the 2020 scalability goal fully realised, this will ensure Ethereum runs performantly on at least 6 year old resource-restricted hardware.

## Extensible, Configurable & Modular Design

The application architecture should have modular abstractions for the following:

1.  Networking Layer

2.  Sub-protocols

3.  Consensus

4.  Privacy

5.  Database

6.  Virtual Machine


And should be built against the Common Compliance Tests: [https://github.com/ethereum/tests](https://github.com/ethereum/tests)

## Ethereum Improvement Proposals Commitment

Nimbus is committed to open standards and maintaining consensus with other compliant Ethereum implementations. Nimbus will do its development and protocol changes via the Ethereum Improvement Proposal process: [https://github.com/ethereum/EIPs/](https://github.com/ethereum/EIPs/)

## User Experience

Access to Shards and Mainchain state should be fast & responsive, the application binary should be lightweight in terms of resources used, and the client should be dependable & robust against crashes.

## Apache v2.0 / MIT Dual Licensing

Another unsolved hurdle Status has faced is the LGPLv3 License as its Runtime Linking requirement is incompatible with mobile app distribution channels (Apple App Store).



There has been numerous requests for a static-linking exception over the past year, it has not materialized, this blocks the ability for any legally sound full Ethereum client being deployed on popular mobile device distribution channels, we’re optimistic this will be eventually rectified. In addition to this, LGPL prevents adoption of Ethereum on closed hardware platforms such as XBox.



We propose to license Nimbus under Apache 2.0 & MIT, a permissive licensing structure with patent protection and ensure compatibility with GPL 2.0 and LGPL 2.0 that will further the reach of the Ethereum platform and ensure highest degree of adoption with governments and enterprise.

## Biweekly Development Reports, Technical Writing & Promotion

In addition to the implementation, Nimbus will have a biweekly process on reporting development updates.



A technical writer that will translate stable research discussion into articles more easily understood by the community as well as document the implementation.



In addition to this, we will also promote Ethereum as the leader of scalable Public Blockchains within the crypto-community.

## Bounty-based Development

Tasks that can be self-contained and well-defined will be put up as Github issues and bounties will be attached to them to entice the community to further accelerate development.


# MILESTONES


Timelines are approximate, will be affected by research and implementation considerations, and will be revised while the team produces a detailed implementation timeline.



## Formation of the Team, and Detailed Implementation of the Project

### January - February 2018

### Completed:

1.  Form the initial team

2.  Define the project’s scope, architecture, and implementation timelines




### Goals:
1.  Hire core contributors:
a.  Five (5) full-time core contributors
b.  Up to five (5) part-time core contributors
c. One (1) Technical Program Manager
c.  One (1) Technical Writer
d. Up to ten (10) full-time core contributors by 2019

2. Create a detailed timeline for implementing the project as a deliverable

## Compatibility with Ethereum 1.0

### January - ~November 2018

As an initial goal, we will focus on implementing all components required for interoperability with the Ethereum ecosystem. However, before starting the implementation in Nim, the team will reference and understand the existing implementations of Ethereum: [Go Ethereum](https://github.com/ethereum/go-ethereum/), [Pyethereum](https://github.com/ethereum/pyethereum), [Py-EVM](https://github.com/ethereum/py-evm), and [Parity](https://github.com/paritytech/parity).



We will strive to publish as much of the developed code as possible. The code will consist of independently reusable libraries that have the same permissive license as that of Nimbus itself. This will include the libraries for the following:

1. RLP encoding and decoding

2. Handling of the state database and users’ key files

3. Connecting to the Ethereum network

4. RLPx sub-protocols

5. Ethereum ETHASH function

6. Implementation of EVM


### Goals:

1. Nimbus is able to
a. Sync with the latest blockchain, from scratch
b. Accurately execute the entire transaction history

3.  The team is familiar with all codebases used to implement Ethereum

4.  The team understands the main themes from [ethresear.ch](https://ethresear.ch/) and actively participates in [EIPs](https://github.com/ethereum/EIPs/)


## Sharding Phase 1

### July - ~November 2018

While implementing compatibility with Ethereum 1.0, we will gain early experience with the complete setup of sharding. As a result:

1.  The client will successfully communicate with other sharding clients that support the Phase 1 protocols.

2.  The team will actively participate in [EIPs](https://github.com/ethereum/EIPs/) related to sharding.


### Goal:
Nimbus architecture supports sharding nodes with split responsibilities




## Auditing of Beta and Security

### ~November 2018 - ~March 2019

An independent security partner will continuously perform a security audit on the Nimbus codebase. We will also adopt practices for enhancing security, such as frequent code reviews and testing with automated fuzzing frameworks. In addition, we will develop a Nim-optimized fuzzing framework and will release it for use by the community at large.

### Goal:
Deliver a security-audited and production-ready client.

## Implementation of Whisper and PSS

### July - October 2018

We will set and advertise bounties as soon as the P2P layer gets implemented; otherwise, the core team will start work in July. If no one picks up the bounties by July, then the core team will pick them up and start work in July.

### Goals:

1.  Make Nimbus the leading platform for conducting research into the scalability aspects of Whisper and PSS. We consider this a key requirement for implementing a fully decentralised Status messaging platform within the Ethereum network.

2.  Deliver easy-to-use APIs for conducting large-scale and small-scale experiments within the network.


## Support for LES

### July - October 2018

We will optimize the architecture of Nimbus for implementing the LES protocol. We will also optimize all internal state-handling operations such that they work efficiently and asynchronously.

This will enable on-demand fetching of data from the network. This will also ensure that Nimbus runs with a high degree of concurrency and that the client UI is responsive.

### Goals:

1.  Enable a Light Mode switch in Nimbus

2.  Successfully operate Nimbus in a mobile environment, without relying on a proxy service


## Implementation of Swarm

### October 2018 - ~March 2019

We will set and advertise bounties as soon as the P2P layer gets implemented; otherwise, the core team will start work in October. If no one picks up the bounties by July, then the core team will pick them up and start work in October.

### Goals:

Implement the following:

1.  Ability to embed Nimbus into applications that deliver the complete Web 3.0 experience

2.  Support for the Ethereum Name Service

3.  Support for a virtual file-system interface for accessing web content published on Swarm

4.  Reusable APIs for publishing and obtaining content from Swarm




## Implementation of Casper

### December 2018 - Feb 2019

The team will closely follow the development of Casper and will try to achieve and maintain compatibility with the existing Casper deployments.



## Release of Sharding Phase 2

### November 2018 - July 2019

We will focus on achieving compatibility with the rest of the clients. In addition, we will implement an eWASM runtime and will add Nim as one of the languages able to target the new VM.



### Goals:

Implement the following in Nim:

1.  Command-line tools and APIs for running Phase 2 nodes and for interacting with the Validator Manager Contract (VMC)

2.  The development tools that will target the eWASM runtime environment




## Release of Sharding Phase 3

### March - August 2019

We will leverage our LES-optimized architecture to deliver a fully stateless client optimized for mobile devices.

### Goals:

Implement support for the following:

1.  Always-on operations on mobile devices, without disrupting the battery life or inducing significant bandwidth charges

2.  Running stateless executor nodes in deployments of headless servers




## Ongoing Improvements in Sharding

### August 2019 - Onward

1. Become one of the leading production-ready sharding implementations in the Ethereum ecosystem

2. Take active part in the effort to specify the new programming models required for cross-shard interactions

3. Provide an ongoing research into the applicability and the performance characteristics of all super-quadratic sharding designs in a mobile environment


The Nimbus team will pursue being one of the leading production-ready sharding implementations in the Ethereum ecosystem. We hope to participate actively in the efforts of specifying the new programming models required for cross-shard interactions. We also hope to provide an ongoing research into the applicability and the performance characteristics of all super-quadratic sharding designs in a mobile environment.

# RESOURCES

1.  [https://github.com/pirapira/awesome-ethereum-virtual-machine](https://github.com/pirapira/awesome-ethereum-virtual-machine)

2.  [https://github.com/ethereum/sharding/blob/develop/docs/doc.md](https://github.com/ethereum/sharding/blob/develop/docs/doc.md)

3.  [https://github.com/ethereum/wiki/wiki/Sharding-FAQ](https://github.com/ethereum/wiki/wiki/Sharding-FAQ)

4.  [https://www.youtube.com/watch?v=9RtSod8EXn4&feature=youtu.be&t=11493](https://www.youtube.com/watch?v=9RtSod8EXn4&feature=youtu.be&t=11493)

5.  [https://ethresear.ch/t/the-stateless-client-concept/172](https://ethresear.ch/t/the-stateless-client-concept/172)

6.  [https://www.youtube.com/watch?v=hAhUfCjjkXc](https://www.youtube.com/watch?v=hAhUfCjjkXc)

7.  [https://github.com/ethereum/py-evm/issues?q=is%3Aopen+is%3Aissue+label%3ASharding](https://github.com/ethereum/py-evm/issues?q=is%3Aopen+is%3Aissue+label%3ASharding)

8.  [https://github.com/ethereum/py-evm/pulls?q=is%3Aopen+is%3Apr+label%3ASharding](https://github.com/ethereum/py-evm/pulls?q=is%3Aopen+is%3Apr+label%3ASharding)

9.  [https://github.com/ethereum/py-evm/tree/sharding](https://github.com/ethereum/py-evm/tree/sharding)

10.  [https://ethresear.ch/c/sharding](https://ethresear.ch/c/sharding)

11.  [https://gitter.im/ethereum/research](https://gitter.im/ethereum/research)

12.  [https://gitter.im/ethereum/py-evm](https://gitter.im/ethereum/py-evm)

13.  [https://medium.com/@icebearhww/ethereum-sharding-and-finality-65248951f649](https://medium.com/@icebearhww/ethereum-sharding-and-finality-65248951f649)

14.  [https://www.mindomo.com/mindmap/sharding-d7cf8b6dee714d01a77388cb5d9d2a01](https://www.mindomo.com/mindmap/sharding-d7cf8b6dee714d01a77388cb5d9d2a01)

15.  [https://blog.ethereum.org/2016/05/09/on-settlement-finality/](https://blog.ethereum.org/2016/05/09/on-settlement-finality/)

16.  [https://ethresear.ch/t/casper-contract-and-full-pos/136/2](https://ethresear.ch/t/casper-contract-and-full-pos/136/2)

17.  [https://medium.com/@jonchoi/ethereum-casper-101-7a851a4f1eb0](https://medium.com/@jonchoi/ethereum-casper-101-7a851a4f1eb0)

18.  [http://notes.eth.sg/MYEwhswJwMzAtADgCwEYBM9kAYBGJ4wBTETKdGZdXAVmRvUQDYg=?view#](http://notes.eth.sg/MYEwhswJwMzAtADgCwEYBM9kAYBGJ4wBTETKdGZdXAVmRvUQDYg=?view#)

19.  [https://github.com/ethersphere/swarm/wiki/Light-mode-of-operation](https://github.com/ethersphere/swarm/wiki/Light-mode-of-operation)




# IMPLEMENTATION THOUGHTS

Need to create [devp2p](https://github.com/ethereum/wiki/wiki/%C3%90%CE%9EVp2p-Wire-Protocol) (and abstraction to potentially allow for [libp2p](https://github.com/Agorise/c-libp2p)), [Node Discovery](https://github.com/ethereum/wiki/wiki/Node-discovery-protocol), [RLP encoding](https://github.com/ethereum/wiki/wiki/RLP), [Modified Patricia Merkle Tree](https://easythereentropy.wordpress.com/2014/06/04/understanding-the-ethereum-trie/) , [bigint’s](https://github.com/def-/nim-bigints), keccak256 and secp256k1.



Ontop of this we need an abstraction to allow for sub protocols (ETH, [SHH](https://gist.github.com/gluk256/9812e59ed0481050350a11308ada4096), [PSS](https://gist.github.com/zelig/d52dab6a4509125f842bbd0dce1e9440), [Swarm](https://github.com/ethersphere/swarm), [LES](https://github.com/ethereum/wiki/wiki/Light-client-protocol)/Stateless Clients/Sharding, Plasma(?)/State Channels) although we can ignore almost all of these for now, with the exception of LES/Sharding



DB: Most Eth implementations use Leveldb, Parity has a db abstraction and uses hashdb and rocksdb.

Rocksdb is an interesting choice as it solves issues leveldb comes in contact with and they have a [lite version](https://github.com/facebook/rocksdb/blob/master/ROCKSDB_LITE.md) for mobile usage but is C++ which is an issue only if we go for pure C.



EVM virtual machine - basic vm, [eWASM](https://github.com/ewasm/design) (Hera is also C++)



IPC/RPC abstraction, [external API methods](https://github.com/ethereum/wiki/wiki/JSON-RPC) that can be consumed by application bindings (react-native module, IPC, RPC http server or web sockets)


Encryption Library is a little unclear, Libgcrypt has everything we need but may be problematic LGPL licensing standpoint, we could use it now if we have abstraction for it and swap it out later for something more permissive, or roll our own (not a great idea to do own encryption will definitely need to be audited and tested if we do), open to suggestions.



Need to monitor [https://github.com/ethereum/py-evm/tree/sharding](https://github.com/ethereum/py-evm/tree/sharding) and connect with Chang-Wu Chen, Hsiao-Wei Wang and ??? who are working on sharding
