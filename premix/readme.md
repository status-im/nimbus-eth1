# Premix

> Premix was **pre**mium(subsidized gasoline)   **mix**ed [with lubricant oil]
used for two stroke internal combustion engines and it tends to produce a lot
of smoke.

Today premix is a block validation debugging tool targeting at nimbus ethereum
client. Premix will query transaction execution steps from other ethereum
clients and compare it with nimbus'.

Premix then will produce a web page to present comparison result that can be
inspected by developer to pinpoint where the faulty instruction located.

Premix will also produce a test case for the specific problematic transaction
complete with snapshot database to execute transaction validation in isolation.
This test case then can be integrated with nimbus project test suite.
