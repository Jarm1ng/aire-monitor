import HPCCore
// Named to sort first: a missing module is a fatal error that stops the
// compiler before it parses later files, so this hint must be parsed before
// any file that imports Testing. Without it the only message is "no such
// module 'Testing'", which does not say how to fix it.
#if !canImport(Testing)
#error("swift-testing is not on the module search path. With Command Line Tools only, run Tests/AIREMonitorAppTests/run_tests.sh, which adds -F for the CLT's Testing.framework.")
#endif
