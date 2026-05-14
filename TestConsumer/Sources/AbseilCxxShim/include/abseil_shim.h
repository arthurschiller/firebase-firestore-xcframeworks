#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

// Returns length of absl::StrCat(a, b). Exercises absl::AlphaNum +
// absl::strings_internal::CatPieces — both must be in the linked archive.
size_t absl_shim_strcat_len(const char* a, const char* b);

#ifdef __cplusplus
}
#endif
