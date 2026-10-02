#include "zip_reader.h"

#include <vector>
#include <cstring>

#include <zlib.h>

namespace msoh {

namespace {

constexpr uint32_t kEocdSig = 0x06054b50;
constexpr uint32_t kCdEntrySig = 0x02014b50;
constexpr uint32_t kLocalHeaderSig = 0x04034b50;

uint16_t rd16(const uint8_t* p)
{
    return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

uint32_t rd32(const uint8_t* p)
{
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8)
        | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

bool HasSuffixCI(const std::string& name, const std::string& suffix)
{
    if (name.size() < suffix.size()) {
        return false;
    }
    for (size_t i = 0; i < suffix.size(); ++i) {
        char a = name[name.size() - suffix.size() + i];
        char b = suffix[i];
        if (a >= 'A' && a <= 'Z') {
            a = static_cast<char>(a - 'A' + 'a');
        }
        if (b >= 'A' && b <= 'Z') {
            b = static_cast<char>(b - 'A' + 'a');
        }
        if (a != b) {
            return false;
        }
    }
    return true;
}

bool InflateRaw(const uint8_t* src, size_t srcLen, std::vector<uint8_t>& out, size_t expectedSize)
{
    out.clear();
    if (expectedSize > 0) {
        out.reserve(expectedSize);
    }
    z_stream zs{};
    zs.next_in = const_cast<Bytef*>(src);
    zs.avail_in = static_cast<uInt>(srcLen);

    // -15: raw deflate stream (no zlib/gzip header)
    if (inflateInit2(&zs, -15) != Z_OK) {
        return false;
    }
    std::vector<uint8_t> chunk(64 * 1024);
    int ret = Z_OK;
    do {
        zs.next_out = chunk.data();
        zs.avail_out = static_cast<uInt>(chunk.size());
        ret = inflate(&zs, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) {
            inflateEnd(&zs);
            return false;
        }
        out.insert(out.end(), chunk.data(), chunk.data() + (chunk.size() - zs.avail_out));
    } while (ret != Z_STREAM_END && zs.avail_in > 0);
    inflateEnd(&zs);
    return ret == Z_STREAM_END;
}

} // namespace

std::string ReadEntryBySuffix(const uint8_t* data, size_t size, const std::string& suffix,
                              std::string& entryName, std::string& error)
{
    error.clear();
    entryName.clear();
    if (size < 22) {
        error = "not a zip (too small)";
        return {};
    }

    // Find End Of Central Directory record: scan backwards, max 64KB comment.
    const size_t scanMax = size < (64 * 1024 + 22) ? size : (64 * 1024 + 22);
    const uint8_t* eocd = nullptr;
    for (size_t back = 22; back <= scanMax; ++back) {
        const uint8_t* p = data + size - back;
        if (rd32(p) == kEocdSig) {
            eocd = p;
            break;
        }
    }
    if (!eocd) {
        error = "EOCD not found";
        return {};
    }

    uint16_t entries = rd16(eocd + 10);
    uint64_t cdOffset = rd32(eocd + 16);

    // Walk central directory entries.
    std::vector<ZipEntryInfo> infos;
    infos.reserve(entries);
    const uint8_t* p = data + cdOffset;
    for (uint16_t i = 0; i < entries; ++i) {
        if (static_cast<size_t>(p - data) + 46 > size || rd32(p) != kCdEntrySig) {
            error = "bad central directory";
            return {};
        }
        ZipEntryInfo info{};
        info.method = rd16(p + 10);
        info.compSize = rd32(p + 20);
        info.uncompSize = rd32(p + 24);
        uint16_t nameLen = rd16(p + 28);
        uint16_t extraLen = rd16(p + 30);
        uint16_t commentLen = rd16(p + 32);
        info.localHeaderOffset = rd32(p + 42);
        info.name.assign(reinterpret_cast<const char*>(p + 46), nameLen);
        infos.push_back(info);
        p += 46 + nameLen + extraLen + commentLen;
    }

    const ZipEntryInfo* target = nullptr;
    for (const auto& info : infos) {
        if (HasSuffixCI(info.name, suffix)) {
            if (!target || info.name.size() < target->name.size()) {
                target = &info;
            }
        }
    }
    if (!target) {
        error = "no *" + suffix + " entry in zip";
        return {};
    }

    // Local header: skip its own name/extra fields before the payload.
    const uint8_t* lh = data + target->localHeaderOffset;
    if (static_cast<size_t>(lh - data) + 30 > size || rd32(lh) != kLocalHeaderSig) {
        error = "bad local header";
        return {};
    }
    uint16_t lhNameLen = rd16(lh + 26);
    uint16_t lhExtraLen = rd16(lh + 28);
    const uint8_t* payload = lh + 30 + lhNameLen + lhExtraLen;
    if (static_cast<size_t>(payload - data) + target->compSize > size) {
        error = "truncated entry data";
        return {};
    }

    entryName = target->name;
    std::vector<uint8_t> out;
    if (target->method == 0) {
        out.assign(payload, payload + target->compSize);
    } else if (target->method == 8) {
        if (!InflateRaw(payload, target->compSize, out, target->uncompSize)) {
            error = "inflate failed for " + target->name;
            return {};
        }
    } else {
        error = "unsupported compression method";
        return {};
    }
    return std::string(out.begin(), out.end());
}

} // namespace msoh
