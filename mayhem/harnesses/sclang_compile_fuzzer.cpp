// libFuzzer harness for sclang's compiler: the input is sclang source text, compiled (never run)
// exactly as `"...".compile` does it: Interpreter:compile -> _CompileExpression (prCompileString in
// lang/LangPrimSource/PyrPrimitive.cpp), i.e. the lexer, the bison parser and the bytecode compiler
// in lang/LangSource (PyrLexer.cpp, PyrParseNode.cpp), with their diagnostics.
//
// Setup (once, in LLVMFuzzerInitialize) mirrors sclang's own start-up (SC_TerminalClient::run):
// a language client, initRuntime, a library config (sclang_conf.yaml with the standard
// SCClassLibrary plus mayhem/sclang/FuzzCompile.sc, found next to this binary), compileLibrary.
// Per input: setCmdLine(input) and runLibrary(\fuzzCompile), the same two calls sclang makes for
// every command line it interprets. State kept across inputs, on purpose: the compiled class library
// (read-only to compilation) and the symbol table, which interns identifiers just like a long-running
// sclang session. The compiled Function is garbage and is reclaimed by sclang's GC.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <unistd.h>

#include "SC_LanguageClient.h"
#include "SC_LanguageConfig.hpp"

namespace {
class FuzzClient : public SC_LanguageClient {
public:
    FuzzClient(): SC_LanguageClient("sclang") {}
    void postText(const char*, size_t) override {}
    void postFlush(const char*, size_t) override {}
    void postError(const char*, size_t) override {}
    void flush() override {}
};
FuzzClient* g_client = nullptr;
}

extern "C" int LLVMFuzzerInitialize(int*, char***) {
    namespace fs = std::filesystem;
    const fs::path root = fs::canonical("/proc/self/exe").parent_path(); // the source tree (/mayhem)
    const char* tmp = getenv("TMPDIR");
    std::string templ = std::string(tmp && *tmp ? tmp : "/tmp") + "/sclang-fuzz-XXXXXX";
    std::vector<char> buf(templ.begin(), templ.end());
    buf.push_back('\0');
    if (!mkdtemp(buf.data())) {
        perror("mkdtemp");
        abort();
    }
    const fs::path dir = buf.data();
    // sclang keeps its user data under $HOME; give it the scratch dir instead of the image.
    setenv("HOME", dir.c_str(), 1);
    const fs::path conf = dir / "sclang_conf.yaml";
    {
        std::ofstream y(conf);
        y << "includePaths:\n  - " << (root / "SCClassLibrary").string() << "\n  - "
          << (root / "mayhem" / "sclang").string() << "\nexcludePaths: []\nexcludeDefaultPaths: true\n";
    }
    g_client = new FuzzClient();
    SC_LanguageClient::Options opt;
    g_client->initRuntime(opt);
    SC_LanguageConfig::setConfigPath(conf);
    SC_LanguageConfig::readLibraryConfig(false);
    if (!g_client->compileLibrary(false)) {
        fprintf(stderr, "sclang_compile_fuzzer: class library failed to compile\n");
        abort();
    }
    // sclang's own exit path (SC_TerminalClient::run): shut the library and runtime down, which
    // joins the scheduler/OSC threads before static destructors run.
    atexit([] {
        g_client->shutdownLibrary();
        g_client->shutdownRuntime();
    });
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    g_client->setCmdLine(reinterpret_cast<const char*>(data), size);
    g_client->runLibrary("fuzzCompile"); // takes the client lock itself
    return 0;
}
