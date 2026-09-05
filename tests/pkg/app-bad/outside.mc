// outside.mc -- a real, readable, compilable file that a package still may not
// read: it sits one level above the package's own tree. It exists so that the
// closure refusal is proved to be the closure and not a missing file.
i64 outside_value() { return 7; }
