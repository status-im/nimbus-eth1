FROM debian:buster-slim AS build

RUN apt-get update \
 && apt-get install -y --fix-missing build-essential make git libpcre3-dev librocksdb-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ARG GIT_REVISION
ENV NPROC=2

RUN git clone https://github.com/status-im/nimbus-eth1.git \
 && cd nimbus-eth1 \
 && git reset --hard ${GIT_REVISION} \
 && make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" V=1 update

RUN cd nimbus-eth1 && \
    make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" nimbus && \
    mv build/nimbus /usr/bin/

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:buster-slim AS deploy

RUN apt-get update \
 && apt-get install -y librocksdb-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /usr/bin/nimbus /usr/bin/nimbus

MAINTAINER Zahary Karadjov <zahary@status.im>
LABEL description="Nimbus: an Ethereum 2.0 Sharding Client for Resource-Restricted Devices"

ENTRYPOINT ["/usr/bin/nimbus"]
