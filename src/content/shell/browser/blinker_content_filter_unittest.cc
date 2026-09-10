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
  static BlinkerContentFilter* Create() {
    auto* filter = new BlinkerContentFilter;
    filter->LoadBuiltinList();
    filter->BuildGenericCSS();
    filter->loaded_ = true;
    return filter;
  }

  static void Destroy(BlinkerContentFilter* filter) { delete filter; }

  static void ParseFilterLine(BlinkerContentFilter& filter,
                              std::string_view line) {
    filter.ParseFilterLine(line);
  }
};

namespace {

class BlinkerContentFilterTest : public testing::Test {
 protected:
  void SetUp() override {
    filter_ = BlinkerContentFilterTestPeer::Create();
    filter().SetEnabled(true);
  }

  void TearDown() override { BlinkerContentFilterTestPeer::Destroy(filter_); }

  BlinkerContentFilter& filter() { return *filter_; }

 private:
  BlinkerContentFilter* filter_ = nullptr;
};

TEST_F(BlinkerContentFilterTest, BlocksHostsAndSubdomains) {
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://doubleclick.net/ad")));
  EXPECT_TRUE(
      filter().ShouldBlock(GURL("https://stats.g.doubleclick.net/pixel")));
  EXPECT_TRUE(
      filter().ShouldBlock(GURL("https://connect.facebook.net/script.js")));
}

TEST_F(BlinkerContentFilterTest, DoesNotPromotePathRulesToWholeHosts) {
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "||facebook.com/tr^$image");
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://facebook.com/")));
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://facebook.com/messages")));

  // Path exceptions must not disable blocking for the entire host.
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "||path-exception.test^");
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://path-exception.test/ad.js")));
  BlinkerContentFilterTestPeer::ParseFilterLine(
      filter(), "@@||path-exception.test/allowed/widget.js");
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://path-exception.test/ad.js")));
  EXPECT_TRUE(
      filter().ShouldBlock(GURL("https://sub.path-exception.test/ad.js")));
}

TEST_F(BlinkerContentFilterTest, HostExceptionOverridesParentBlock) {
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "||example-ad-network.test^");
  EXPECT_TRUE(filter().ShouldBlock(
      GURL("https://login.example-ad-network.test/script.js")));
  BlinkerContentFilterTestPeer::ParseFilterLine(
      filter(), "@@||login.example-ad-network.test^");
  EXPECT_FALSE(filter().ShouldBlock(
      GURL("https://login.example-ad-network.test/script.js")));
  EXPECT_TRUE(filter().ShouldBlock(
      GURL("https://pixel.example-ad-network.test/script.js")));
}

TEST_F(BlinkerContentFilterTest, IgnoresConstrainedNetworkRules) {
  constexpr std::string_view kSuffixes[] = {
      "^$script",      "^$domain=example.com",
      "^$third-party", "*",
      "?query",        "^path",
      "/allowed.js",   "|"};
  for (std::string_view suffix : kSuffixes) {
    SCOPED_TRACE(suffix);
    BlinkerContentFilterTestPeer::ParseFilterLine(
        filter(), "||scoped.test" + std::string(suffix));
    EXPECT_FALSE(filter().ShouldBlock(GURL("https://scoped.test/ad.js")));
    BlinkerContentFilterTestPeer::ParseFilterLine(
        filter(), "@@||doubleclick.net" + std::string(suffix));
    EXPECT_TRUE(filter().ShouldBlock(GURL("https://doubleclick.net/ad.js")));
  }
}

TEST_F(BlinkerContentFilterTest, DoesNotMatchPublicSuffixes) {
  for (const char* rule : {"||co.uk^", "||github.io^", "||com^"}) {
    BlinkerContentFilterTestPeer::ParseFilterLine(filter(), rule);
  }
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://ads.example.co.uk/ad.js")));
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://project.github.io/ad.js")));
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://example.com/ad.js")));

  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "||example.co.uk^");
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://ads.example.co.uk/ad.js")));
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://other.co.uk/ad.js")));
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "@@||co.uk^");
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://ads.example.co.uk/ad.js")));
}

TEST_F(BlinkerContentFilterTest, PreservesSubdomainAndTrailingDotScope) {
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "||example.test^");
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "@@||www.example.test^");
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://www.example.test/ad.js")));
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://ads.example.test/ad.js")));
  EXPECT_TRUE(filter().ShouldBlock(GURL("https://ADS.EXAMPLE.TEST./ad.js")));
  EXPECT_FALSE(filter().ShouldBlock(GURL("https://notexample.test/ad.js")));
}

TEST_F(BlinkerContentFilterTest, CosmeticRulesRespectPublicSuffixBoundaries) {
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "co.uk##.suffix-ad");
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "github.io##.tenant-ad");
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "example.co.uk##.site-ad");
  EXPECT_EQ(filter().CosmeticCSSFor("other.co.uk").find(".suffix-ad"),
            std::string::npos);
  EXPECT_EQ(filter().CosmeticCSSFor("project.github.io").find(".tenant-ad"),
            std::string::npos);
  EXPECT_NE(filter().CosmeticCSSFor("ads.example.co.uk").find(".site-ad"),
            std::string::npos);
}

TEST_F(BlinkerContentFilterTest, AllowsHumanVerificationAndAccountResources) {
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "||recaptcha.net^");
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "||challenges.cloudflare.com^");
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(),
                                                "||accounts.google.com^");
  BlinkerContentFilterTestPeer::ParseFilterLine(filter(), "||google.com^");

  EXPECT_FALSE(
      filter().ShouldBlock(GURL("https://www.recaptcha.net/recaptcha/api.js")));
  EXPECT_FALSE(filter().ShouldBlock(
      GURL("https://challenges.cloudflare.com/turnstile/v0/api.js")));
  EXPECT_FALSE(filter().ShouldBlock(
      GURL("https://accounts.google.com/o/oauth2/v2/auth")));
  EXPECT_FALSE(filter().ShouldBlock(
      GURL("https://www.google.com/recaptcha/api2/anchor")));
  EXPECT_TRUE(
      filter().ShouldBlock(GURL("https://www.google.com/ordinary-resource")));
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
