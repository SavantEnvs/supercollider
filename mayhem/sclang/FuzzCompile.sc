// Class extensions the sclang_compile_fuzzer harness adds to the standard class library: compile
// (do not run) the interpreter's command line, which the harness sets to the fuzz input. This is the
// String:compile path (Interpreter:compile -> _CompileExpression -> prCompileString).
+ Interpreter {
	fuzzCompileCmdLine { ^this.compile(cmdLine) }
}

+ Main {
	fuzzCompile { ^interpreter.fuzzCompileCmdLine }
}
