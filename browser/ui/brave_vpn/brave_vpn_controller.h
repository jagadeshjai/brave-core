/* Copyright (c) 2024 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

#ifndef BRAVE_BROWSER_UI_BRAVE_VPN_BRAVE_VPN_CONTROLLER_H_
#define BRAVE_BROWSER_UI_BRAVE_VPN_BRAVE_VPN_CONTROLLER_H_

#include "base/memory/raw_ptr.h"
#include "brave/components/brave_vpn/common/mojom/brave_vpn.mojom.h"

class BraveBrowserView;
class BrowserView;

class BraveVPNController {
 public:
  explicit BraveVPNController(BrowserView* browser_view);
  ~BraveVPNController();
  BraveVPNController(const BraveVPNController&) = delete;
  BraveVPNController& operator=(const BraveVPNController&) = delete;

  void ShowBraveVPNBubble(bool show_select = false);
  void OpenVPNAccountPage(brave_vpn::mojom::ManageURLType type);

 private:
  BraveBrowserView* GetBraveBrowserView();

  raw_ptr<BrowserView> browser_view_ = nullptr;
};

#endif  // BRAVE_BROWSER_UI_BRAVE_VPN_BRAVE_VPN_CONTROLLER_H_
