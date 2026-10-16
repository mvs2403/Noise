#pragma once
#include <filesystem>
#include <stdexcept>
#include <string>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#define NR_LIBRARY(name) name ".dll"
#elif defined(__APPLE__)
#include <dlfcn.h>
#define NR_LIBRARY(name) "lib" name ".dylib"
#else
#include <dlfcn.h>
#define NR_LIBRARY(name) "lib" name ".so"
#endif

namespace noise {
inline void *openLibrary(const std::string &path) {
#ifdef _WIN32
    auto library = LoadLibraryExW(std::filesystem::u8path(path).c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!library) throw std::runtime_error("Cannot load engine: " + path + " (Windows " + std::to_string(GetLastError()) + ")");
    return reinterpret_cast<void *>(library);
#else
    auto library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!library) throw std::runtime_error(std::string("Cannot load engine: ") + dlerror());
    return library;
#endif
}
inline void closeLibrary(void *library) {
#ifdef _WIN32
    if (library) FreeLibrary(reinterpret_cast<HMODULE>(library));
#else
    if (library) dlclose(library);
#endif
}
template<class T> T symbol(void *library, const char *name) {
#ifdef _WIN32
    auto address = GetProcAddress(reinterpret_cast<HMODULE>(library), name);
#else
    auto address = dlsym(library, name);
#endif
    if (!address) throw std::runtime_error(std::string("The installed runtime is missing ") + name);
    return reinterpret_cast<T>(address);
}
}
