// libFuzzer harness for sclang's standalone lexer (langutils/sc_lexer), driven exactly as
// langutils/sc_lexer/standalone/main.cpp does: normalise the source text, lex it token by token
// until EndOfFile, and map every token range back to its text. The input is sclang source code.
#include <cstddef>
#include <cstdint>
#include <string>

#include "codepoint_stream.hpp"
#include "lexer.hpp"
#include "normalise_source.hpp"
#include "text_location.hpp"

using namespace sc::lex;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    // main.cpp gets its source from argv, i.e. NUL-free text measured with strlen().
    std::string text(reinterpret_cast<const char*>(data), size);
    if (text.find('\0') != std::string::npos)
        return -1;
    NormalisedSource src { text.c_str(), text.size() };
    CodePointStream stream { src, {} };
    actions::TypeAndLocationAction action {};
    size_t total = 0;
    for (auto r = lexer(stream, action); r.type != TokenType::EndOfFile; r = lexer(stream, action)) {
        const auto [ptr, sz] = stream.source_code_range_to_text(r.range);
        total += sz;
        if (sz)
            total += static_cast<unsigned char>(ptr[0]) + static_cast<unsigned char>(ptr[sz - 1]);
        (void)to_string(r.type);
    }
    volatile size_t sink = total;
    (void)sink;
    return 0;
}
