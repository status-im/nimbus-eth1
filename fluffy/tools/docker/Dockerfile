FROM debian:buster-slim AS build

RUN apt-get update \
 && apt-get install -y --fix-missing build-essential make git libpcre3-dev librocksdb-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ARG BRANCH_NAME=master
ENV NPROC=2

RUN git clone https://github.com/status-im/nimbus-eth1.git \
 && cd nimbus-eth1 \
 && git checkout ${BRANCH_NAME} \
 && git pull \
 && make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" V=1 update

RUN cd nimbus-eth1 && \
    make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" fluffy && \
    mv build/fluffy /usr/bin/

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:buster-slim AS deploy

RUN apt-get update \
 && apt-get install -y librocksdb-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /usr/bin/fluffy /usr/bin/fluffy

ENTRYPOINT ["/usr/bin/fluffy"]
