# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

FROM debian:testing-slim AS build

SHELL ["/bin/bash", "-c"]

RUN apt-get clean && apt update \
 && apt -y install curl build-essential git-lfs librocksdb-dev

RUN ldd --version ldd

ADD . /root/nimbus-eth1

RUN cd /root/nimbus-eth1 \
 && make -j$(nproc) update-from-ci \
 && make -j$(nproc) V=1 LOG_LEVEL=TRACE nimbus

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:testing-slim as deploy

SHELL ["/bin/bash", "-c"]
RUN apt-get clean && apt update \
 && apt -y install build-essential librocksdb-dev
RUN apt update && apt -y upgrade

RUN ldd --version ldd

RUN rm -f /home/user/nimbus-eth1/build/nimbus_execution_client

COPY --from=build /root/nimbus-eth1/build/nimbus_execution_client /home/user/nimbus-eth1/build/nimbus_execution_client

ENV PATH="/home/user/nimbus-eth1/build:${PATH}"
ENTRYPOINT ["nimbus_execution_client"]
WORKDIR /home/user/nimbus-eth1/build

STOPSIGNAL SIGINT