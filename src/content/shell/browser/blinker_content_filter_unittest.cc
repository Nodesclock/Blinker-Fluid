// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_content_filter.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

extern "C" __attribute__((weak)) void BlinkBootLog(const char*) {}

namespace content {

class BlinkerContentFilterTestPeer {
 public:
  static void ParseFilterLine(BlinkerContentFilter& filter,
                              std::string_view line) {
    filter.ParseFilterLine(line);
  }
};

namespace {

class BlinkerContentFilterTest : public testing::Test {
 protected:
  void SetUp() override {
    filter().EnsureLoaded();
    filter().SetEnabled(true);
  }

  BlinkerContentFilter& filter() {
    return BlinkerContentFilter::GetInstance();
  }
};

TEST_F(BlinkerContentFilterTest, BlocksHostsAndSubdomains) {
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://doubleclick.net/ad")));
  EXPECT_TRUE(
      filter().ShouldBlock(GURL("https://stats.g.doubleclick.net/pixel")));
  EXPECT_TRUE(
      filter().ShouldBlock(GURL("https://connect.facebook.net/script.js")));
}

TEST_F(BlinkerContentFilterTest, DoesNotPromotePathRulesToWholeHosts) {
  BlinkerContentFilterTestPeer::ParseFilterLine(
      filter(), "||facebook.com/tr^$image");
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://facebook.com/")));
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://facebook.com/messages")));
}

TEST_F(BlinkerContentFilterTest, IgnoresMalformedNetworkRules) {
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "|");
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "||");
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://facebook.com/")));
}

TEST_F(BlinkerContentFilterTest, IgnoresUnsupportedSchemesAndInvalidUrls) {
  EXPECT_FALSE(filter().ShouldBlock(GURL("about:blank")));
  EXPECT_FALSE(filter().ShouldBlock(GURL("file:///tmp/doubleclick.net")));
  EXPECT_FALSE(filter().ShouldBlock(GURL()));
}

TEST_F(BlinkerContentFilterTest, ProducesCosmeticRulesWhenEnabled) {
  const std::string css = filter().CosmeticCSSFor("example.com");
  EXPECT_NE(css.find(".adsbygoogle"), std::string::npos);
  EXPECT_NE(css.find("display:none!important"), std::string::npos);

  filter().SetEnabled(false);
  EXPECT_TRUE(filter().CosmeticCSSFor("example.com").empty());
  filter().SetEnabled(true);
}

TEST_F(BlinkerContentFilterTest, CountsBlockedRequests) {
  const uint64_t before = filter().blocked_count();
  filter().RecordBlocked();
  EXPECT_EQ(before + 1, filter().blocked_count());
}

}  // namespace
}  // namespace content
