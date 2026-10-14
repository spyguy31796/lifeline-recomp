// Unit test for the PS2_INPUT_MAP parser: c++ -std=c++20 -I.. ../input_map.cpp test_input_map.cpp && ./a.out
#include "input_map.hpp"
#include <cstdio>
using namespace lifeline_input;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)
int main() {
    Map m; std::string e;
    CHECK(parse_map("", m, e) && m.active);
    CHECK(m.src[kCircle].size() == 1 && m.src[kCircle][0].kind == Kind::Button && m.src[kCircle][0].index == 1);  // default b
    e.clear();
    CHECK(parse_map("circle = paddle1, b ; cross=a;l2=lefttrigger; up=-lefty; select=none; square=key:Space; lx=rightx; ly=righty~;"
                    "r1=joy:b7; r2=joy:a5+; down=joy:h0.down", m, e));
    CHECK(m.src[kCircle].size() == 2 && m.src[kCircle][0].index == 16 && m.src[kCircle][1].index == 1);
    CHECK(m.src[kUp][0].kind == Kind::Axis && m.src[kUp][0].index == 1 && m.src[kUp][0].sign == -1);
    CHECK(m.bound[kSelect] && m.src[kSelect].empty());
    CHECK(m.src[kSquare][0].kind == Kind::Key && m.src[kSquare][0].key == "Space");
    CHECK(m.src[kLX][0].index == 2 && !m.src[kLX][0].invert && m.src[kLY][0].index == 3 && m.src[kLY][0].invert);
    CHECK(m.src[kR1][0].kind == Kind::JoyButton && m.src[kR1][0].index == 7);
    CHECK(m.src[kR2][0].kind == Kind::JoyAxis && m.src[kR2][0].index == 5 && m.src[kR2][0].sign == 1);
    CHECK(m.src[kDown][0].kind == Kind::JoyHat && m.src[kDown][0].hat_mask == 4);
    CHECK(m.src[kTriangle][0].index == 3);                         // untouched -> default y
    e.clear();
    CHECK(!parse_map("bogus=a; circle=zz; lx=a; cross=x", m, e));  // bad entries reported, good ones kept
    CHECK(!e.empty() && m.src[kCross][0].index == 2 && m.src[kCircle][0].index == 1 && m.src[kLX][0].index == 0);
    e.clear(); CHECK(!parse_map("up=+a", m, e));                   // sign on a button is invalid
    e.clear(); CHECK(!parse_map("down=joy:h0.sideways", m, e));
    int t; CHECK(target_from_name(" Circle ", t) && t == kCircle);
    std::printf(fails ? "%d FAILED\n" : "all input_map tests passed\n", fails);
    return fails != 0;
}
