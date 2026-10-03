# Portal
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

FROM debian:trixie-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      make \
      git \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

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

FROM debian:trixie-slim AS deploy

RUN apt-get update \
 && apt-get install -y --no-install-recommends ethtool net-tools \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /bin/utp_test_app /bin/utp_test_app

COPY setup.sh .
RUN chmod +x setup.sh

COPY run_endpoint.sh .
RUN chmod +x run_endpoint.sh

ENTRYPOINT [ "./run_endpoint.sh" ]
