* Refactor `handlers_tracer`. This module can reliably work only as a genuine
  logger. The restore features were ill concieved, an attempt to be as close
  as possible to the legacy tracer.
