#include "murmur_mt.h"
#include <iostream>

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  char *error = nullptr;
  auto *engine = murmur_mt_open(argv[1], &error);
  if (!engine) {
    std::cerr << (error ? error : "model failed without a message") << '\n';
    murmur_mt_string_free(error);
    return 1;
  }
  char *output = murmur_mt_translate(engine, argv[2], &error);
  const bool success = output && output[0] && !error;
  if (success) std::cout << output << '\n';
  else std::cerr << (error ? error : "empty translation") << '\n';
  murmur_mt_string_free(output);
  murmur_mt_string_free(error);
  murmur_mt_close(engine);
  return success ? 0 : 1;
}
