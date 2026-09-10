// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/common/blinker_site_policy.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace content::blinker_sites {
namespace {

TEST(BlinkerSitePolicyTest, MatchesCompleteDomainLabels) {
  EXPECT_TRUE(HostMatchesDomain("example.com", "example.com"));
  EXPECT_TRUE(HostMatchesDomain("www.example.com", "example.com"));
  EXPECT_TRUE(HostMatchesDomain("www.example.com.", "example.com"));
  EXPECT_FALSE(HostMatchesDomain("notexample.com", "example.com"));
  EXPECT_FALSE(HostMatchesDomain("example.com.attacker.test", "example.com"));
  EXPECT_FALSE(HostMatchesDomain("", "example.com"));
}

TEST(BlinkerSitePolicyTest, KeepsMemoryAndKeyboardPoliciesIndependent) {
  EXPECT_TRUE(HasTrait("www.youtube.com", kHeavy));
  EXPECT_FALSE(HasTrait("www.youtube.com", kChatKeyboard));
  EXPECT_TRUE(HasTrait("github.com", kMonitorMemory));
  EXPECT_FALSE(HasTrait("github.com", kAI));
  EXPECT_TRUE(HasTrait("chatgpt.com", kAI));
  EXPECT_TRUE(HasTrait("chatgpt.com", kChatKeyboard));
  EXPECT_FALSE(HasTrait("chatgpt.com.attacker.test", kChatKeyboard));
}

TEST(BlinkerSitePolicyTest, ServiceExceptionsAreExact) {
  EXPECT_TRUE(HasTrait("accounts.google.com", kVerificationResource));
  EXPECT_FALSE(HasTrait("other.accounts.google.com", kVerificationResource));
  EXPECT_FALSE(HasTrait("google.com", kVerificationResource));
  EXPECT_TRUE(HasTrait("www.recaptcha.net", kVerificationResource));
  EXPECT_FALSE(HasTrait("notrecaptcha.net", kVerificationResource));
}

TEST(BlinkerSitePolicyTest, KeepsRestoreRestrictionsNarrow) {
  EXPECT_TRUE(HasTrait("mail.google.com", kSkipSessionRestore));
  EXPECT_TRUE(HasTrait("old.reddit.com", kSkipSessionRestore));
  EXPECT_FALSE(HasTrait("github.com", kSkipSessionRestore));
  EXPECT_FALSE(HasTrait("youtube.com", kSkipSessionRestore));
  EXPECT_FALSE(HasTrait("example.test", kHeavy));
}

}  // namespace
}  // namespace content::blinker_sites
