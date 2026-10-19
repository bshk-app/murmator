#include "include/murmur_mt.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "common/logging.h"
#include "spdlog/spdlog.h"
#include "translator/parser.h"
#include "translator/response.h"
#include "translator/response_options.h"
#include "translator/service.h"

namespace {

char *duplicate(const std::string &value) {
  char *out = static_cast<char *>(std::malloc(value.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, value.data(), value.size());
  out[value.size()] = '\0';
  return out;
}

void report(char **error_out, const std::string &message) {
  if (error_out != nullptr) *error_out = duplicate(message);
}

bool blank(const char *utf8) {
  for (const char *p = utf8; *p != '\0'; ++p) {
    if (!std::isspace(static_cast<unsigned char>(*p))) return false;
  }
  return true;
}

}  // namespace

struct MurmurMTEngine {
  std::unique_ptr<marian::bergamot::BlockingService> service;
  std::shared_ptr<marian::bergamot::TranslationModel> model;
};

MurmurMTEngine *murmur_mt_open(const char *config_path, char **error_out) {
  if (config_path == nullptr) {
    report(error_out, "config path is null");
    return nullptr;
  }
  try {
    // Marian defaults to aborting the process on model/config errors. Keep
    // those failures inside this C boundary, including lazy graph creation.
    // The switch is process-global: write it once before any engine is used.
    static std::once_flag exceptionMode;
    std::call_once(exceptionMode, [] { marian::setThrowExceptionOnAbort(true); });

    // marian registers process-global spdlog loggers named "general" and
    // "valid" while parsing a config, and registering a name twice throws.
    // Loading a second model therefore fails - which is every pivot, since a
    // pivot is two models in one process. Dropping first makes loading
    // idempotent; the loggers themselves are of no use inside an app that
    // never reads marian's stderr.
    spdlog::drop_all();

    marian::bergamot::BlockingService::Config serviceConfig;
    auto engine = std::make_unique<MurmurMTEngine>();
    engine->service =
        std::make_unique<marian::bergamot::BlockingService>(serviceConfig);
    auto options = marian::bergamot::parseOptionsFromFilePath(config_path);
    // The binary loader otherwise trusts tensor lengths from the file and
    // can read beyond a partially downloaded model before it can throw.
    options->set("check-bytearray", true);
    engine->model =
        std::make_shared<marian::bergamot::TranslationModel>(options);

    // Marian builds its graph lazily, so a caller timing its first real
    // segment would otherwise be timing model construction. Pay it here.
    std::vector<std::string> warm = {"ok"};
    std::vector<marian::bergamot::ResponseOptions> warmOptions = {
        marian::bergamot::ResponseOptions()};
    engine->service->translateMultiple(engine->model, std::move(warm),
                                       warmOptions);
    return engine.release();
  } catch (const std::exception &error) {
    report(error_out, error.what());
    return nullptr;
  } catch (...) {
    // marian aborts through its own error type on a bad config; keep it inside
    // the C boundary rather than letting it unwind into Swift.
    report(error_out, "unknown error while loading the translation model");
    return nullptr;
  }
}

char *murmur_mt_translate(MurmurMTEngine *engine, const char *utf8,
                          char **error_out) {
  if (engine == nullptr || utf8 == nullptr) {
    report(error_out, "engine or input is null");
    return nullptr;
  }
  if (blank(utf8)) return duplicate("");
  try {
    std::vector<std::string> sources = {std::string(utf8)};
    std::vector<marian::bergamot::ResponseOptions> options = {
        marian::bergamot::ResponseOptions()};
    auto responses = engine->service->translateMultiple(
        engine->model, std::move(sources), options);
    if (responses.empty()) {
      report(error_out, "translator returned no response");
      return nullptr;
    }
    std::string text = responses.front().target.text;
    // The sentence splitter keeps its separators; one segment in is one line
    // out, so collapse them.
    for (char &c : text) {
      if (c == '\n' || c == '\r') c = ' ';
    }
    return duplicate(text);
  } catch (const std::exception &error) {
    report(error_out, error.what());
    return nullptr;
  } catch (...) {
    report(error_out, "unknown error while translating");
    return nullptr;
  }
}

void murmur_mt_close(MurmurMTEngine *engine) { delete engine; }

void murmur_mt_string_free(char *value) { std::free(value); }
