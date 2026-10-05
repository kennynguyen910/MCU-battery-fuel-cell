#pragma once
#include <cstddef>

inline void secureZero(void* memory, std::size_t size)
{
    volatile unsigned char* bytes = static_cast<volatile unsigned char*>(memory);
    while (size--) *bytes++ = 0;
}

// Wipes temporary credential-bearing stack objects on every return path.
class SensitiveScope {
public:
    SensitiveScope(void* memory, std::size_t size) : memory_(memory), size_(size) {}
    ~SensitiveScope() { secureZero(memory_, size_); }
    SensitiveScope(const SensitiveScope&) = delete;
    SensitiveScope& operator=(const SensitiveScope&) = delete;
private:
    void* memory_;
    std::size_t size_;
};
