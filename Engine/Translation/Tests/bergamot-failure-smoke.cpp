#include "murmur_mt.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;

static void expectLoadError(const fs::path &config) {
  char *error = nullptr;
  auto *engine = murmur_mt_open(config.c_str(), &error);
  const bool reported = error != nullptr && error[0] != '\0';
  const std::string message = error ? error : "no error message";
  murmur_mt_string_free(error);
  if (engine) murmur_mt_close(engine);
  if (engine || !reported)
    throw std::runtime_error("Damaged model did not return an error: " + message);
  std::cout << config.parent_path().filename() << ": " << message << '\n';
}

int main(int argc, char **argv) {
  if (argc < 2 || argc > 3) return 2;
  for (const auto *name : {"missing", "truncated"}) {
    const auto directory = fs::path(argv[1]) / name;
    fs::create_directories(directory);
    const auto config = directory / "config.bergamot.yml";
    std::ofstream(config) <<
        "relative-paths: true\n"
        "models: [model.bin]\n"
        "vocabs: [vocab.spm, vocab.spm]\n"
        "shortlist: [lex.bin, false]\n"
        "beam-size: 1\nnormalize: 1.0\nword-penalty: 0\n"
        "mini-batch: 1\nmaxi-batch: 1\nmaxi-batch-sort: src\n"
        "workspace: 2000\nmax-length-factor: 2.5\n"
        "gemm-precision: int8shiftAlphaAll\nmini-batch-words: 1024\n"
        "max-length-break: 128\nssplit-mode: sentence\n";
    if (std::string(name) == "truncated") {
      for (const auto *file : {"model.bin", "vocab.spm", "lex.bin"})
        std::ofstream(directory / file, std::ios::binary);
    }
    // Repeated failures must remain recoverable within the same process.
    expectLoadError(config);
    expectLoadError(config);
  }
  if (argc == 3) {
    // Use real vocab/shortlist files so partial weights reach Marian's binary
    // loader. Tiny files in the checks above fail earlier during pack loading.
    const auto directory = fs::path(argv[1]) / "truncated-weights";
    fs::create_directories(directory);
    fs::path weights;
    for (const auto &entry : fs::directory_iterator(fs::path(argv[2]).parent_path())) {
      if (!entry.is_regular_file()) continue;
      const auto target = directory / entry.path().filename();
      if (entry.path().filename().string().rfind("model.", 0) == 0) {
        weights = target;
        char prefix[1024];
        std::ifstream input(entry.path(), std::ios::binary);
        input.read(prefix, sizeof(prefix));
        std::ofstream(target, std::ios::binary).write(prefix, input.gcount());
      } else {
        fs::copy_file(entry.path(), target, fs::copy_options::overwrite_existing);
      }
    }
    if (weights.empty()) throw std::runtime_error("No binary weights in supplied model pack");
    expectLoadError(directory / fs::path(argv[2]).filename());
    fs::resize_file(weights, 0);
    expectLoadError(directory / fs::path(argv[2]).filename());
    char *error = nullptr;
    auto *engine = murmur_mt_open(argv[2], &error);
    if (!engine) throw std::runtime_error(error ? error : "valid model failed");
    char *output = murmur_mt_translate(engine, "Привет, мир.", &error);
    const bool translated = output != nullptr && output[0] != '\0' && error == nullptr;
    if (output) std::cout << "Valid model after failures: " << output << '\n';
    murmur_mt_string_free(output);
    murmur_mt_string_free(error);
    murmur_mt_close(engine);
    if (!translated) throw std::runtime_error("valid model did not translate");
  }
}
