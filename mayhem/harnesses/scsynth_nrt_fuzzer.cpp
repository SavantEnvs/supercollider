// libFuzzer harness for scsynth's non-real-time renderer (the `scsynth -N` path).
//
// Default build (scsynth_nrt): the fuzz input IS an NRT score file -- the format `scsynth -N <score>`
// reads: a sequence of [int32 big-endian length][OSC bundle]. Every OSC command, /d_recv synthdef
// blob, node and UGen it reaches runs through the real scsynth code (World_New ->
// World_NonRealTimeSynthesis -> World_Cleanup, as server/scsynth/scsynth_main.cpp does).
//
// -DSC_FUZZ_SYNTHDEF (scsynth_synthdef): the fuzz input IS a binary SynthDef file (SCgf). It is
// delivered the way a client does: as the blob of a /d_recv message in a score, followed by an /s_new
// of the def named in the file header, and rendered for 50 ms.
//
// Per input this does what scsynth_main.cpp does for `-N`: World_New, World_NonRealTimeSynthesis
// (which ends with World_Cleanup(world, true)) or, when it throws, World_Cleanup(world, true). That
// cleanup unloads the plugins and frees the UGen/command tables, which World_New builds only on its
// first call (a function-local gLibInitted), so the harness rebuilds them with the same
// initializeLibrary() call before the next World_New. Nothing else is kept across inputs: each input
// gets a fresh World and library, and its scratch directory is emptied before every run. The score's file commands (/b_write,
// /d_load, /b_read, ...) are confined to that directory by the server's own restricted-path option.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <vector>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <sndfile.h>

#include "SC_WorldOptions.h"
#include "SC_World.h"
#include "SC_HiddenWorld.h"
#include "SC_Lib_Cintf.h"

static std::string g_dir, g_score, g_out;

static void empty_dir(const std::string& dir) {
    DIR* d = opendir(dir.c_str());
    if (!d)
        return;
    while (struct dirent* e = readdir(d)) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        std::string p = dir + "/" + e->d_name;
        struct stat st;
        if (lstat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
            empty_dir(p);
            rmdir(p.c_str());
        } else {
            unlink(p.c_str());
        }
    }
    closedir(d);
}

extern "C" int LLVMFuzzerInitialize(int*, char***) {
    const char* tmp = getenv("TMPDIR");
    std::string templ = std::string(tmp && *tmp ? tmp : "/tmp") + "/scsynth-fuzz-XXXXXX";
    std::vector<char> buf(templ.begin(), templ.end());
    buf.push_back('\0');
    if (!mkdtemp(buf.data())) {
        perror("mkdtemp");
        abort();
    }
    g_dir = buf.data();
    g_score = g_dir + "/score.osc";
    g_out = g_dir + "/out.wav";
    return 0;
}

static void put32(std::string& s, uint32_t v) {
    char b[4] = { char(v >> 24), char(v >> 16), char(v >> 8), char(v) };
    s.append(b, 4);
}
static void putstr(std::string& s, const char* p, size_t n) {
    s.append(p, n);
    s.append(4 - (n % 4), '\0');
}
static void putstr(std::string& s, const char* p) { putstr(s, p, strlen(p)); }

// One score frame: [len][#bundle][timetag][len][message]
static void put_bundle(std::string& score, uint64_t timetag, const std::string& msg) {
    std::string b("#bundle\0", 8);
    put32(b, uint32_t(timetag >> 32));
    put32(b, uint32_t(timetag));
    put32(b, msg.size());
    b += msg;
    put32(score, b.size());
    score += b;
}

#ifdef SC_FUZZ_SYNTHDEF
static std::string make_score(const uint8_t* data, size_t size) {
    std::string score, m;
    putstr(m, "/d_recv");
    putstr(m, ",b");
    put32(m, size);
    m.append(reinterpret_cast<const char*>(data), size);
    m.append((4 - size % 4) % 4, '\0');
    put_bundle(score, 0, m);
    // SCgf header: "SCgf" int32 version, int16 numDefs, then the first def's pstring name.
    if (size > 11) {
        size_t n = data[10];
        if (11 + n <= size && n > 0) {
            std::string s;
            putstr(s, "/s_new");
            putstr(s, ",siii");
            putstr(s, reinterpret_cast<const char*>(data + 11), n);
            put32(s, 1000);
            put32(s, 0);
            put32(s, 0);
            put_bundle(score, 0, s);
        }
    }
    std::string q;
    putstr(q, "/n_free");
    putstr(q, ",i");
    put32(q, 1000);
    put_bundle(score, uint64_t(0.05 * 4294967296.0), q);
    return score;
}
#else
// World_NonRealTimeSynthesis renders every 64-sample block up to the last bundle's time tag
// (server/scsynth/SC_World.cpp), so render time and the size of the output file grow with the time
// tag, not with the input. Like libFuzzer's -max_len, bound the rendered length: scores whose
// bundles ask for more than 0.25 s of audio (about 170 blocks at 44.1 kHz) are rejected. This cap
// bounds only how long a score renders; it is not a validity check, and every command, synthdef
// and UGen is still reachable within it (the seeds all end by 0.1 s; the synthdef target renders
// 50 ms).
static bool render_bounded(const uint8_t* data, size_t size) {
    const uint64_t limit = uint64_t(1) << 30; // 0.25 s as an OSC time tag (32.32 fixed point)
    size_t off = 0;
    while (off + 4 <= size) {
        uint32_t len = (uint32_t(data[off]) << 24) | (uint32_t(data[off + 1]) << 16) | (uint32_t(data[off + 2]) << 8)
            | data[off + 3];
        off += 4;
        if (len > size - off)
            break;
        if (len >= 16) {
            uint64_t t = 0;
            for (int i = 0; i < 8; ++i)
                t = (t << 8) | data[off + 8 + i];
            if (t > limit)
                return false;
        }
        off += len;
    }
    return true;
}
#endif

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
#ifdef SC_FUZZ_SYNTHDEF
    std::string score = make_score(data, size);
#else
    if (!render_bounded(data, size))
        return -1;
    std::string score(reinterpret_cast<const char*>(data), size);
#endif
    empty_dir(g_dir);
    FILE* f = fopen(g_score.c_str(), "wb");
    if (!f)
        abort();
    fwrite(score.data(), 1, score.size(), f);
    fclose(f);
    // The score is read from stdin (mNonRealTimeCmdFilename = nullptr), like `scsynth -N _ ...`;
    // the renderer leaves its command FILE open when it throws, and stdin is the one stream
    // we can reopen per input.
    if (!freopen(g_score.c_str(), "rb", stdin))
        abort();

    WorldOptions options;
    options.mRealTime = false;
    options.mVerbosity = -2;
    options.mLoadGraphDefs = false;
    options.mNumBuffers = 64;
    options.mMaxNodes = 256;
    options.mMaxGraphDefs = 256;
    options.mNumAudioBusChannels = 128;
    options.mNumControlBusChannels = 1024;
    options.mRealTimeMemorySize = 8192;
    options.mNumInputBusChannels = 0;
    options.mNumOutputBusChannels = 2;
    options.mPreferredSampleRate = 44100;
    options.mPreferredHardwareBufferFrameSize = 1024;
    options.mNonRealTimeCmdFilename = nullptr;
    options.mNonRealTimeInputFilename = nullptr;
    options.mNonRealTimeOutputFilename = g_out.c_str();
    options.mNonRealTimeOutputHeaderFormat = "WAV";
    options.mNonRealTimeOutputSampleFormat = "int16";
    options.mRestrictedPath = g_dir.c_str();

    static bool first = true;
    if (!first && !gCmdLib)
        initializeLibrary(options.mUGensPluginPath);
    first = false;

    World* world = World_New(&options);
    if (!world)
        abort();
    try {
        World_NonRealTimeSynthesis(world, &options); // calls World_Cleanup(world, true)
    } catch (const std::exception&) {
        // scsynth_main.cpp: "NRT synthesis failed: ..." then World_Cleanup(world, true). The renderer
        // does not close its output file when it throws; close it so descriptors don't run out.
        if (world->hw->mNRTOutputFile) {
            sf_close(world->hw->mNRTOutputFile);
            world->hw->mNRTOutputFile = nullptr;
        }
        if (world->hw->mNRTInputFile) {
            sf_close(world->hw->mNRTInputFile);
            world->hw->mNRTInputFile = nullptr;
        }
        World_Cleanup(world, true);
    }
    return 0;
}
