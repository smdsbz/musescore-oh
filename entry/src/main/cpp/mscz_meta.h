#ifndef MSOH_MSCZ_META_H
#define MSOH_MSCZ_META_H

#include <cstdint>
#include <cstddef>
#include <string>

// Transitional native metadata reader, structured after MuseScore's
// src/engraving/rw version-dispatch design (read114/206/302/400/460/500).
// Qt-free on purpose: the real engraving engine needs Qt6, which is not yet
// available for OpenHarmony. When it lands, this module is replaced by
// engraving's own readers.
namespace msoh {

// Returns a JSON object string with the same fields as ArkTS MsczMetadata.
// On failure returns empty string and fills `error`.
std::string ExtractMetaJson(const uint8_t* data, size_t size, std::string& error);

} // namespace msoh

#endif
