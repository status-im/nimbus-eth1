FROM statusteam/nim-base
MAINTAINER Zahary Karadjov <zahary@status.im>

ARG network
ARG network_backend

RUN apt-get update && apt-get install -y build-essential make librocksdb-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN git clone https://github.com/status-im/nimbus.git && \
    cd nimbus && \
    make update deps

RUN cd nimbus && \
    set -a && \
    . vendor/nim-beacon-chain/scripts/${network}.env && \
    ./env.sh nim \
      -o:/usr/bin/beacon_node \
      -d:release \
      -d:with$network_backend \
      -d:SHARD_COUNT=$SHARD_COUNT \
      -d:SLOTS_PER_EPOCH=$SLOTS_PER_EPOCH \
      -d:chronicles_sinks=json \
      c vendor/nim-beacon-chain/beacon_chain/beacon_node.nim

ENTRYPOINT ["beacon_node"]

