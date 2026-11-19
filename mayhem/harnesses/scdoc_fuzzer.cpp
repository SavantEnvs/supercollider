// libFuzzer harness for the SCDoc help-file parser (SCDoc/: flex lexer, bison grammar, doc tree).
// The input is a .schelp document. It goes through the public entry point scdoc_parse_file(), as
// SCDoc/main.cpp and sclang's _SCDoc_ParseFile primitive use it, in all three parse modes, and every
// tree it returns is freed with doc_node_free_tree().
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <unistd.h>

#include "SCDoc.h"

// The parser reports through these two hooks; sclang and SCDoc/main.cpp each provide them.
void error(const char*, ...) {}
void post(const char*, ...) {}

static std::string g_path;

extern "C" int LLVMFuzzerInitialize(int*, char***) {
    const char* tmp = getenv("TMPDIR");
    std::string templ = std::string(tmp && *tmp ? tmp : "/tmp") + "/scdoc-fuzz-XXXXXX.schelp";
    std::vector<char> buf(templ.begin(), templ.end());
    buf.push_back('\0');
    int fd = mkstemps(buf.data(), 7);
    if (fd < 0) {
        perror("mkstemps");
        abort();
    }
    close(fd);
    g_path = buf.data();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    FILE* f = fopen(g_path.c_str(), "wb");
    if (!f)
        abort();
    fwrite(data, 1, size, f);
    fclose(f);
    for (int mode : { SCDOC_PARSE_FULL, SCDOC_PARSE_PARTIAL, SCDOC_PARSE_METADATA }) {
        DocNode* n = scdoc_parse_file(g_path, mode);
        if (n)
            doc_node_free_tree(n);
    }
    return 0;
}
