#include <stdint.h>

#ifdef _WIN32
__declspec(dllexport)
#endif
int32_t negate(int32_t a) {
    return -a;
}
