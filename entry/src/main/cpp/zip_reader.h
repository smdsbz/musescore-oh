#ifndef MSOH_ZIP_READER_H
#define MSOH_ZIP_READER_H

#include <cstdint>
#include <cstddef>
#include <string>

// Minimal ZIP reader for .mscz containers (read-only).
// Locates the *.mscx entry and inflates it with zlib raw-deflate.
namespace msoh {

struct ZipEntryInfo {
    std::string name;
    uint16_t method;      // 0 = stored, 8 = deflate
    uint32_t compSize;
    uint32_t uncompSize;
    uint64_t localHeaderOffset;
};

// Returns the raw decompressed content of the first entry whose name ends with suffix,
// or an empty vector with `error` set on failure.
std::string ReadEntryBySuffix(const uint8_t* data, size_t size, const std::string& suffix,
                              std::string& entryName, std::string& error);

} // namespace msoh

#endif
