**Nimbus - An Ethereum 2.0 Sharding Client**

- [Overview](#overview)
- [Goals](#goals)
- [Requirements](#requirements)
	- [Requirement: Nim](#requirement--nim)
	- [Requirement: Development on Embedded Systems](#requirement--development-on-embedded-systems)
	- [Requirement: Extensible, Configurable, and Modular Design](#requirement--extensible--configurable--and-modular-design)
	- [Requirement: Commitment to Ethereum Improvement Proposals (EIP)](#requirement--commitment-to-ethereum-improvement-proposals-eip)
	- [Requirement: User Experience](#requirement--user-experience)
	- [Requirement: Dual Licensing of MIT and Apache v2.0](#requirement--dual-licensing-of-mit-and-apache-v20)
	- [Requirement: Biweekly Development Reports, Technical Writing, and Promotion](#requirement--biweekly-development-reports--technical-writing--and-promotion)
	- [Requirement: Bounty-Based Development](#requirement--bounty-based-development)
- [Milestones](#milestones)
	- [Milestone: Formation of the Team, and Detailed Implementation of the Project](#milestone--formation-of-the-team--and-detailed-implementation-of-the-project)
		- [January - February 2018](#january---february-2018)
		- [Completed:](#completed)
		- [Goals:](#goals)
	- [Milestone: Compatibility with Ethereum 1.0](#milestone--compatibility-with-ethereum-10)
		- [January - ~November 2018](#january---november-2018)
		- [Goals:](#goals)
	- [Milestone: Sharding Phase 1](#milestone--sharding-phase-1)
		- [July - ~November 2018](#july---november-2018)
		- [Goal:](#goal)
	- [Auditing of Beta and Security](#auditing-of-beta-and-security)
		- [~November 2018 - ~March 2019](#november-2018---march-2019)
		- [Goal:](#goal)
	- [Milestone: Implementation of Whisper and PSS](#milestone--implementation-of-whisper-and-pss)
		- [July - October 2018](#july---october-2018)
		- [Goals:](#goals)
	- [Milestone: Support for LES](#milestone--support-for-les)
		- [July - October 2018](#july---october-2018)
		- [Goals:](#goals)
	- [Milestone: Implementation of Swarm](#milestone--implementation-of-swarm)
		- [October 2018 - ~March 2019](#october-2018---march-2019)
		- [Goals:](#goals)
	- [Milestone: Implementation of Casper](#milestone--implementation-of-casper)
		- [December 2018 - Feb 2019](#december-2018---feb-2019)
	- [Milestone: Release of Sharding Phase 2](#milestone--release-of-sharding-phase-2)
		- [November 2018 - July 2019](#november-2018---july-2019)
		- [Goals:](#goals)
	- [Milestone: Release of Sharding Phase 3](#milestone--release-of-sharding-phase-3)
		- [March - August 2019](#march---august-2019)
		- [Goals:](#goals)
	- [Milestone: Ongoing Improvements in Sharding](#milestone--ongoing-improvements-in-sharding)
		- [August 2019 - Onward](#august-2019---onward)
		- [Goals:](#goals)
- [Ideas Considered for Implementation](#ideas-considered-for-implementation)
- [Resources](#resources)

<!-- /TOC -->
# Overview

Nimbus aims to be a [sharding](https://github.com/ethereum/wiki/wiki/Sharding-FAQ) client implementation for the Ethereum Blockchain Application Platform. Because the largest deployment of Ethereum will be on embedded systems, Nimbus will be designed to perform well on IoT and personal mobile devices, including older smartphones with resource-restricted hardware. The extensible, configurable, and modular design of Nimbus will make it production ready for Web 3.0 and will ensure that it can be supported and maintained across all goals of Ethereum 2.0.

# Goals

1.  Create an Ethereum implementation suitable for resource-restricted devices.

2.  Create an implementation team for the [Applied Research Objectives](https://hackmd.io/s/HkLkj55yb#objectives-in-applied-research) of [Ethereum Research](http://ethereumresearch.org/) (aka Ethereum Asia Pacific Limited), with focus on the following:

	a. Proof of Stake (PoS)

	b. Sharding

	c. Stateless Clients

	d. LES2

	e. eWASM

3.  Close the gap between research modeling and production.

4.  Pledge to participate in, help implement, and conform to the [Ethereum Improvement Proposal](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1.md).

5. Implement permissive licensing.

6.  Focus on production-ready [Web 3.0](https://medium.com/@matteozago/why-the-web-3-0-matters-and-you-should-know-about-it-a5851d63c949) Stack ([Whisper](https://github.com/ethereum/wiki/wiki/Whisper), [PSS](https://github.com/nolash/psstalk/blob/master/README.md), and [Swarm](https://swarm-guide.readthedocs.io/en/latest/introduction.html)) and its ongoing research and development.

7.  Focus on marketing and promotion to address community concerns on scalability and to bolster Ethereum’s dominant mindshare.


# Requirements

## Requirement: Nim

[Nim](https://nim-lang.org/) is an efficient, general-purpose systems programming language with a Python-like syntax that compiles to C. Nim will allow us to implement Ethereum rapidly and to take advantage of the mature C-language tooling both in compilation of machine code and in the analysis of static code.

With Ethereum research currently modeled in Python, the end result of implementing in Nim should be code that

 - Enables us to easily bring research into production
 - Has a high degree of reasonability for researchers
 - Is performant in production

The core contributors and Nim community have been very supportive and enthusiastic for the project.

## Requirement: Development on Embedded Systems

We believe that the largest successful deployment of Ethereum will reside on embedded systems: IoT devices and mobile personal devices, such as smartphones.

Existing implementations of Ethereum have focused on desktop computers and servers. These implementations played a major role in the successful debut of Ethereum, and they are suitable for full and archival nodes. However, their deployment onto embedded systems has been an afterthought.

In addition, throughout the development of Status, we have found that the dominant Ethereum implementations, Geth and Parity, are unsuitable for our target platform unless they are profiled and optimised (in progress).

Although Nimbus will support archival nodes, its first implementation will be as a light client, with focus on Proof of Stake and sharding.

During the deployment of Status among 40,000 alpha testers, we found that a significant portion (23.6%) of users were still running old mobile devices. In addition, recently discovered [Spectre vulnerabilities](https://en.wikipedia.org/wiki/Spectre_(security_vulnerability)) have led to an increase in the demand for open processors. For these reasons, we propose a self-imposed constraint and a requirement that Status perform well on the following:

1. 2014 [SoC](https://en.wikipedia.org/wiki/System_on_a_chip) architectures, such as the [Cortex-A53](https://developer.arm.com/products/processors/cortex-a/cortex-a53) (Samsung Note 4 & [Raspberry Pi 3](https://www.raspberrypi.org/products/raspberry-pi-3-model-b/)) and the Apple A8 (iPhone 6)

2. [MIPS](https://en.wikipedia.org/wiki/MIPS_architecture)-based architectures, such as the [Onion Omega2](https://onion.io/omega2/)

3. Open-source processors, such as [RISC-V](https://en.wikipedia.org/wiki/RISC-V)

When the 2020 scalability goal is fully realised, this constraint will help ensure that Ethereum runs performantly on resource-restricted hardware that is at least 6 years old.

## Requirement: Extensible, Configurable, and Modular Design
The application architecture should have modular abstractions for the following:

1.  Networking layer

2.  Sub-protocols

3.  Consensus

4.  Privacy

5.  Database

6.  Virtual Machine

In addition, the implementation must pass the [common tests for all Ethereum implementations](https://github.com/ethereum/tests).

## Requirement: Commitment to Ethereum Improvement Proposals (EIP)

Nimbus is committed to open standards and to maintaining consensus with other Ethereum-compliant implementations. The development of Nimbus and the changes in its protocols will follow [the EIP process](https://github.com/ethereum/EIPs/).

## Requirement: User Experience

Access to shards and the mainchain state should be fast and responsive, the application binary should be lightweight in terms of resources used, and the client should be dependable and robust against crashes.

## Requirement: Dual Licensing of MIT and Apache v2.0  

One unsolved hurdle faced by Status is the [LGPLv3](https://opensource.org/licenses/LGPL-3.0) license, whose requirement for runtime linking is incompatible with major mobile app distribution channels, such as the App Store of Apple Inc.

Numerous requests for a static-linking exception have been made but not answered. This has blocked the deployment of any legally sound, full Ethereum client on popular channels for distribution of mobile devices. LGPL also prevents the adoption of Ethereum on closed hardware platforms, such as XBox. Still, we remain optimistic this issue will be rectified.

We propose that Nimbus be licensed under Apache 2.0 and MIT. A permissive licensing structure with patent protection would
1. Ensure the compatibility with GPL 2.0 and LGPL 2.0
2. Further the reach of the Ethereum platform
3. Foster the highest degree of adoption by governments and enterprise

## Requirement: Biweekly Development Reports, Technical Writing, and Promotion

In addition to the implementation, Nimbus will have a biweekly process for reporting development-related updates.

A technical writer will document implementation efforts and translate ongoing research discussions into articles easily understood by the community.

Within the community at large, we will promote Ethereum as the leader of scalable public blockchains.

## Requirement: Bounty-Based Development

To entice the community to accelerate the development, we will attach bounties to and [publish](https://openbounty.status.im/app#/) the tasks that can be self-contained and defined clearly.

# Milestones

Timelines are approximate and affected by research, implementation considerations, and revisions made while the team produces a detailed implementation timeline.


## Milestone: Formation of the Team, and Detailed Implementation of the Project

### January - February 2018

### Completed:
1.  Form the initial team

2.  Define the project’s scope, architecture, and implementation timelines

### Goals:
1.  Hire core contributors:

    a.  Five (5) full-time core contributors

    b.  Up to five (5) part-time core contributors

    c. One (1) Technical Program Manager

    d.  One (1) Technical Writer

	e. Up to ten (10) full-time core contributors by 2019


2. Create a detailed timeline for implementing the project as a deliverable

## Milestone: Compatibility with Ethereum 1.0

### January - ~November 2018

As an initial goal, we will focus on implementing all components required for interoperability with the Ethereum ecosystem. However, before starting the implementation in Nim, the team will reference and understand the existing implementations of Ethereum: [Go Ethereum](https://github.com/ethereum/go-ethereum/), [Pyethereum](https://github.com/ethereum/pyethereum), [Py-EVM](https://github.com/ethereum/py-evm), and [Parity](https://github.com/paritytech/parity).

We will strive to publish as much of the developed code as possible. The code will consist of independently reusable libraries that have the same permissive license as that of Nimbus itself. This will include the libraries for the following:

1. [RLP](https://github.com/ethereum/wiki/wiki/RLP) encoding and decoding

2. Handling of the state database and users’ key files

3. Connecting to the Ethereum network

4. [RLPx](https://github.com/ethereum/devp2p/blob/master/rlpx.md#introduction) sub-protocols

5. Ethereum [Ethash](https://github.com/ethereum/wiki/wiki/Ethash) function

6. Implementation of EVM


### Goals:

1. Nimbus is able to

	a. Sync with the latest blockchain, from scratch

    b. Accurately execute the entire transaction history

3.  The team is familiar with all codebases used to implement Ethereum.

4.  The team understands the main themes from [ethresear.ch](https://ethresear.ch/) and actively participates in EIPs.


## Milestone: Sharding Phase 1

### July - ~November 2018

While implementing compatibility with Ethereum 1.0, we will gain early experience with the complete setup of sharding. As a result:

1.  The client will successfully communicate with other sharding clients that support the Phase 1 protocols.

2.  The team will actively participate in sharding-related EIPs.


### Goal:
The architecture of Nimbus supports sharding nodes with split responsibilities.


## Auditing of Beta and Security

### ~November 2018 - ~March 2019

An independent security partner will continuously perform a security audit on the Nimbus codebase. We will also adopt frequent reviews of code, testing with automated fuzzing frameworks, and other practices that enhance security. In addition, we will develop a Nim-optimized fuzzing framework and will release it for use by the community at large.

### Goal:
Deliver a security-audited, production-ready client.

## Milestone: Implementation of Whisper and PSS

### July - October 2018

We will set and advertise bounties as soon as the P2P layer gets implemented. If no one picks up the bounties by July 2018, then the core team will pick them up and start work in July.

### Goals:

1.  Make Nimbus the leading platform for conducting research into the scalability aspects of Whisper and PSS. We consider this a key requirement for implementing a fully decentralised Status messaging platform within the Ethereum network.

2.  Deliver easy-to-use APIs for conducting large-scale and small-scale experiments within the network.


## Milestone: Support for LES

### July - October 2018

We will optimize the architecture of Nimbus for implementing the [LES protocol](https://github.com/ethereum/wiki/wiki/Light-client-protocol). We will also optimize all internal state-handling operations such that they work efficiently and asynchronously. This will enable on-demand fetching of data from the network. This will also ensure that Nimbus runs with a high degree of concurrency and that the client UI is responsive.

### Goals:

1.  Enable a Light Mode switch in Nimbus.

2.  Successfully operate Nimbus in a mobile environment, without relying on a proxy service.


## Milestone: Implementation of Swarm

### October 2018 - ~March 2019

We will set and advertise bounties as soon as the P2P layer gets implemented. If no one picks up the bounties by October 2018, then the core team will pick them up and start work in October.

### Goals:

Implement the following:

1.  Ability to embed Nimbus into applications that deliver the complete Web 3.0 experience

2.  Support for the [Ethereum Name Service](https://ens.domains/)

3.  Support for a virtual file-system interface for accessing web content published on Swarm

4.  Reusable APIs for publishing and obtaining content from Swarm




## Milestone: Implementation of Casper

### December 2018 - Feb 2019

The team will closely follow the development of [Casper](https://blockgeeks.com/guides/ethereum-casper/) and will try to achieve and maintain compatibility with the existing Casper deployments.



## Milestone: Release of Sharding Phase 2

### November 2018 - July 2019

We will focus on achieving compatibility with the rest of the clients. In addition, we will implement an [eWASM](https://github.com/ewasm/design/blob/master/README.md) runtime and will add Nim as one of the languages able to target the new VM.



### Goals:

Implement the following in Nim:

1.  Command-line tools and APIs for running Phase 2 nodes and for interacting with the Validator Manager Contract (VMC)

2.  The development tools that will target the eWASM runtime environment




## Milestone: Release of Sharding Phase 3

### March - August 2019

We will leverage our LES-optimized architecture to deliver a fully stateless client optimized for mobile devices.

### Goals:

Implement support for the following:

1.  Always-on operations on mobile devices, without disrupting the battery life or inducing significant bandwidth charges

2.  Running stateless executor nodes in deployments of headless servers


## Milestone: Ongoing Improvements in Sharding

### August 2019 - Onward

### Goals:
1. Become one of the leading production-ready sharding implementations in the Ethereum ecosystem.

2. Take active part in the effort to specify the new programming models required for cross-shard interactions.

3. Provide an ongoing research into the applicability and performance characteristics of all super-quadratic sharding designs in a mobile environment.


# Ideas Considered for Implementation

1. Create [devp2p](https://github.com/ethereum/wiki/wiki/%C3%90%CE%9EVp2p-Wire-Protocol) and an abstraction to allow for
   [libp2p](https://github.com/Agorise/c-libp2p), [Node
   Discovery](https://github.com/ethereum/wiki/wiki/Node-discovery-protocol),
   [RLP encoding](https://github.com/ethereum/wiki/wiki/RLP), [Modified Patricia Merkle Tree](https://easythereentropy.wordpress.com/2014/06/04/understanding-the-ethereum-trie/), [bigint’s](https://github.com/def-/nim-bigints), [keccak256](https://github.com/ethereum/eth-hash), and
   [secp256k1](https://en.bitcoin.it/wiki/Secp256k1).

2. Create an abstraction that would allow sub-protocols: ETH,
   [SHH](https://gist.github.com/gluk256/9812e59ed0481050350a11308ada4096), [PSS](https://gist.github.com/zelig/d52dab6a4509125f842bbd0dce1e9440), [Swarm](https://github.com/ethersphere/swarm), [LES](https://github.com/ethereum/wiki/wiki/Light-client-protocol), [Stateless Clients](https://nordicapis.com/defining-stateful-vs-stateless-web-services/), Sharding, [Plasma](https://plasma.io/), [State Channels](https://blog.stephantual.com/what-are-state-channels-32a81f7accab). For now, we can ignore all but LES and Sharding.

3. DB: Most implementations of Ethereum use [LevelDB](https://github.com/google/leveldb). Parity has a DB abstraction and uses [HashDB](https://github.com/NPS-DEEP/hashdb/wiki) and [RocksDB](https://rocksdb.org/docs/getting-started.html).

   RocksDB is an interesting choice, because it solves the issues that have troubled leveldb. Rocksdb also has a [light    version](https://github.com/facebook/rocksdb/blob/master/ROCKSDB_LITE.md) for mobile usage; it's in C++, which would be an issue only if we go for pure C.

4. [EVM](https://github.com/pirapira/awesome-ethereum-virtual-machine): basic VM,
   [eWASM](https://github.com/ewasm/design) ([Hera](https://github.com/ewasm/hera) is also in C++)


5. IPC/RPC abstraction, [external API
   methods](https://github.com/ethereum/wiki/wiki/JSON-RPC) that can be consumed by application bindings: react-native module, IPC, RPC HTTP
   server, or web sockets


6. Encryption library is a little unclear. [Libgcrypt](https://www.gnupg.org/software/libgcrypt/index.html) has everything we need but might be problematic from the standpoint of LGPL licensing. If we have an abstraction for Libgcrypt, we could use it now and swap it out later for something more permissive.

	 Alternatively, we could roll out our own library. However, implementing our own encryption would not be a great idea, and our version would have to be audited and tested. Suggestions are welcome.


7. Monitor
   [ethereum/py-evm](https://github.com/ethereum/py-evm/tree/sharding). Connect with Chang-Wu Chen, Hsiao-Wei Wang, and anyone else working on sharding.

# Resources
1.  [Awesome Ethereum Virtual Machine](https://github.com/pirapira/awesome-ethereum-virtual-machine)

2.  [Detailed introduction to the sharding proposal](https://github.com/ethereum/sharding/blob/develop/docs/doc.md)

3.  [Sharding FAQ](https://github.com/ethereum/wiki/wiki/Sharding-FAQ)

4.  [Ethereum 2.0: A presentation by Vitalik Buterin at BeyondBlock Taipei 2017 ](https://www.youtube.com/watch?v=9RtSod8EXn4&feature=youtu.be&t=11493)

5.  [The Stateless Client Concept](https://ethresear.ch/t/the-stateless-client-concept/172)

6.  [A Modest Proposal for Ethereum 2.0: A presentation by Vitalik Buterin at devcon three](https://youtu.be/hAhUfCjjkXc)

7.  [Python Implementation of the EVM
	 ](https://github.com/ethereum/py-evm/blob/master/README.md)

8.  [Discussion about sharding](https://ethresear.ch/c/sharding)

9.  [Discussion on Casper, scalability, abstraction and other low-level protocol research topics](https://gitter.im/ethereum/research)

10. [ethereum/py-evm](https://gitter.im/ethereum/py-evm)

11. [Ethereum Sharding: Overview and Finality](https://medium.com/@icebearhww/ethereum-sharding-and-finality-65248951f649)

14.  [Sharding - Mind Map](https://www.mindomo.com/mindmap/sharding-d7cf8b6dee714d01a77388cb5d9d2a01)

15.  [On Settlement Finality](https://blog.ethereum.org/2016/05/09/on-settlement-finality/)

16.  [Casper contract and full POS](https://ethresear.ch/t/casper-contract-and-full-pos/136/2)

17.  [Ethereum Casper 101](http://notes.eth.sg/MYEwhswJwMzAtADgCwEYBM9kAYBGJ4wBTETKdGZdXAVmRvUQDYg=?view#)

19.  [ethersphere/swarm, Light mode of operation](https://github.com/ethersphere/swarm/wiki/Light-mode-of-operation)
