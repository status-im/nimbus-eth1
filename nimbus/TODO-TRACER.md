The `handlers_tracer` driver from the `CoreDb` module needs to be re-factored.

This module will slightly change its work modus and will run as a genuine
logger. The previously available restore features were ill concieved, an
attempt to be as close as possible to the legacy tracer. If resoring is
desired the tracer will need to run inside a transaction (which it does
anyway.)
