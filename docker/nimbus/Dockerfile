FROM statusteam/nim-base
MAINTAINER Zahary Karadjov <zahary@status.im>

RUN apt-get update && apt-get install -y build-essential make librocksdb-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN git clone https://github.com/status-im/nimbus.git && \
    cd nimbus && \
    make update deps

RUN cd nimbus && \
    make nimbus && \
    mv build/nimbus /usr/bin/

ENTRYPOINT ["nimbus"]

