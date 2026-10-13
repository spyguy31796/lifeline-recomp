#include "recognizer.hpp"
namespace voice {
namespace {
class NullRecognizer final : public Recognizer {
public:
    void set_vocabulary(const std::vector<std::string> &, const std::vector<int> &) override {}
    void start() override {}
    void stop() override {}
    bool poll(Recognition &) override { return false; }
};
}
std::unique_ptr<Recognizer> make_null_recognizer() { return std::make_unique<NullRecognizer>(); }
}
