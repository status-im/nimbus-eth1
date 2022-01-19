FROM ubuntu:20.04

RUN apt-get update && \
  apt-get install -y build-essential wget net-tools iputils-ping tcpdump ethtool iperf iproute2 make git libpcre3-dev librocksdb-dev curl

ARG BRANCH_NAME=master
ENV NPROC=2

RUN git clone https://github.com/status-im/nimbus-eth1.git \
 && cd nimbus-eth1 \
 && git checkout ${BRANCH_NAME} \
 && git pull \
 && make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" V=1 update

RUN cd nimbus-eth1 && \
    make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" utp-test-app && \
    mv build/utp_test_app /bin/

COPY setup.sh .
RUN chmod +x setup.sh

COPY run_endpoint.sh .
RUN chmod +x run_endpoint.sh

ENTRYPOINT [ "./run_endpoint.sh" ]
