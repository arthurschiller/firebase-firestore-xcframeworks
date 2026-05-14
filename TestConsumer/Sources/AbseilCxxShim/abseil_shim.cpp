#include "abseil_shim.h"
#include <absl/strings/str_cat.h>
#include <string>

extern "C" size_t absl_shim_strcat_len(const char* a, const char* b) {
    std::string result = absl::StrCat(a, b);
    return result.size();
}
