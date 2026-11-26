// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_UPDATE_ASSET_H_
#define CONTENT_SHELL_COMMON_BLINKER_UPDATE_ASSET_H_

#include <initializer_list>
#include <string>
#include <string_view>
#include <vector>

namespace content {

enum class BlinkerBuildVariant {
  kMain,
  kLegacyIOS,
  kSideload,
};

// GitHub міняє пробіли на крапки, тож "iOS 12 Blinker Fluid"
// приходить як "ios.12.blinker.fluid"
inline BlinkerBuildVariant BlinkerUpdateAssetVariant(std::string_view name) {
  for (std::string_view mark :
       {"ios.12", "ios 12", "ios12", "ios.11", "ios 11", "ios11"}) {
    if (name.find(mark) != std::string_view::npos) {
      return BlinkerBuildVariant::kLegacyIOS;
    }
  }
  for (std::string_view mark : {"sideload", "livecontainer"}) {
    if (name.find(mark) != std::string_view::npos) {
      return BlinkerBuildVariant::kSideload;
    }
  }
  return BlinkerBuildVariant::kMain;
}

inline bool BlinkerIsInstallableAsset(std::string_view name) {
  return name.ends_with(".ipa") || name.ends_with(".tipa");
}

// Чужий варіант не пропонуєм ніколи, збірка для iOS 14 на iOS 12
// не стане, а звичайна без розширеної адресації падає на старті
inline int BlinkerPickUpdateAsset(const std::vector<std::string>& names,
                                  bool jit,
                                  BlinkerBuildVariant variant) {
  int any_engine = -1;
  for (size_t i = 0; i < names.size(); ++i) {
    const std::string& name = names[i];
    if (!BlinkerIsInstallableAsset(name) ||
        BlinkerUpdateAssetVariant(name) != variant) {
      continue;
    }
    if ((name.find("jit") != std::string::npos) == jit) {
      return static_cast<int>(i);
    }
    if (any_engine < 0) {
      any_engine = static_cast<int>(i);
    }
  }
  return any_engine;
}

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_UPDATE_ASSET_H_
