import os

/// `Logger` singleton used across the app instead of print statements.
///
/// The subsystem and category are set explicitly. A bare `Logger()` writes to a nameless
/// subsystem that `log show --predicate 'process == "..."'` cannot retrieve, which made a
/// silent writer failure impossible to diagnose after the fact. With a subsystem, errors
/// persist to the unified log and can be read back with:
///
///     log show --predicate 'subsystem == "com.christianmauerer.Timelapsr"' --last 1h
let logger = Logger(subsystem: "com.christianmauerer.Timelapsr", category: "recording")
