// Paths from the environment, as UTF-8. On Windows the narrow CRT (getenv, fopen, std::ifstream(std::string))
// uses the ANSI code page, which cannot hold every path; these read the wide environment and open files by
// their wide name. On Linux they are getenv / fopen / std::filesystem::path(string), i.e. unchanged.
#pragma once
#include <cstdio>
#include <filesystem>
#include <optional>
#include <string>
namespace voice {
std::optional<std::string> env_utf8(const char *name);           // unset -> nullopt
std::filesystem::path u8_path(const std::string &utf8);           // UTF-8 string -> path (for ifstream / iterators)
std::string path_utf8(const std::filesystem::path &p);           // path -> UTF-8 string
std::FILE *fopen_utf8(const std::string &utf8, const char *mode);
// For a library API that only takes a narrow path (vosk_model_new): Windows returns the ANSI code page form,
// else the 8.3 short form, else the UTF-8 string unchanged (and *lossy = true). Linux returns the input.
std::string narrow_api_path(const std::string &utf8, bool *lossy = nullptr);
}
