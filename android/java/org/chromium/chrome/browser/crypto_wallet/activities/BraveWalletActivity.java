/* Copyright (c) 2021 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

package org.chromium.chrome.browser.crypto_wallet.activities;

import static org.chromium.chrome.browser.crypto_wallet.util.Utils.ONBOARDING_ACTION;
import static org.chromium.chrome.browser.crypto_wallet.util.Utils.ONBOARDING_FIRST_PAGE_ACTION;
import static org.chromium.chrome.browser.crypto_wallet.util.Utils.RESTORE_WALLET_ACTION;
import static org.chromium.chrome.browser.crypto_wallet.util.Utils.UNLOCK_WALLET_ACTION;

import android.os.Build;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.ImageView;

import androidx.appcompat.view.menu.MenuBuilder;
import androidx.appcompat.widget.Toolbar;
import androidx.core.content.ContextCompat;
import androidx.viewpager.widget.ViewPager;

import com.google.android.material.tabs.TabLayout;

import org.chromium.base.ActivityState;
import org.chromium.base.ApplicationStatus;
import org.chromium.base.Log;
import org.chromium.brave_wallet.mojom.BraveWalletConstants;
import org.chromium.brave_wallet.mojom.NetworkInfo;
import org.chromium.brave_wallet.mojom.OnboardingAction;
import org.chromium.chrome.R;
import org.chromium.chrome.browser.app.BraveActivity;
import org.chromium.chrome.browser.app.domain.WalletModel;
import org.chromium.chrome.browser.crypto_wallet.adapters.CryptoFragmentPageAdapter;
import org.chromium.chrome.browser.crypto_wallet.adapters.CryptoWalletOnboardingPagerAdapter;
import org.chromium.chrome.browser.crypto_wallet.fragments.PortfolioFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.SwapBottomSheetDialogFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.onboarding_fragments.BackupWalletFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.onboarding_fragments.RecoveryPhraseFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.onboarding_fragments.RestoreWalletFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.onboarding_fragments.SecurePasswordFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.onboarding_fragments.SetupWalletFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.onboarding_fragments.UnlockWalletFragment;
import org.chromium.chrome.browser.crypto_wallet.fragments.onboarding_fragments.VerifyRecoveryPhraseFragment;
import org.chromium.chrome.browser.crypto_wallet.listeners.OnNextPage;
import org.chromium.chrome.browser.crypto_wallet.util.NavigationItem;
import org.chromium.chrome.browser.crypto_wallet.util.Utils;
import org.chromium.chrome.browser.settings.BraveWalletPreferences;
import org.chromium.chrome.browser.settings.SettingsLauncherImpl;
import org.chromium.components.browser_ui.modaldialog.AppModalPresenter;
import org.chromium.components.browser_ui.settings.SettingsLauncher;
import org.chromium.ui.base.ActivityWindowAndroid;
import org.chromium.ui.modaldialog.ModalDialogManager;

import java.util.ArrayList;
import java.util.List;

/**
 * Main Brave Wallet activity
 */
public class BraveWalletActivity extends BraveWalletBaseActivity implements OnNextPage {
    private static final String TAG = "BWalletBaseActivity";

    private Toolbar mToolbar;

    private View mCryptoLayout;
    private View mCryptoOnboardingLayout;
    private ImageView mPendingTxNotification;
    private ImageView mBuySendSwapButton;
    private ViewPager mCryptoWalletOnboardingViewPager;
    private CryptoFragmentPageAdapter mCryptoFragmentPageAdapter;
    private ModalDialogManager mModalDialogManager;
    private CryptoWalletOnboardingPagerAdapter mCryptoWalletOnboardingPagerAdapter;
    private boolean mShowBiometricPrompt;
    private boolean mIsFromDapps;
    private WalletModel mWalletModel;
    private boolean mRestartSetupAction;
    private boolean mRestartRestoreAction;

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        getMenuInflater().inflate(R.menu.wallet_search, menu);

        if (menu instanceof MenuBuilder) {
            ((MenuBuilder) menu).setOptionalIconsVisible(true);
        }
        return super.onCreateOptionsMenu(menu);
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        if (item.getItemId() == R.id.settings) {
            SettingsLauncher settingsLauncher = new SettingsLauncherImpl();
            settingsLauncher.launchSettingsActivity(this, BraveWalletPreferences.class);
            return true;
        } else if (item.getItemId() == R.id.lock) {
            if (mKeyringService != null) {
                mKeyringService.lock();
            }
        }
        return super.onOptionsItemSelected(item);
    }

    @Override
    protected void triggerLayoutInflation() {
        setContentView(R.layout.activity_brave_wallet);
        mIsFromDapps = false;
        if (getIntent() != null) {
            mIsFromDapps = getIntent().getBooleanExtra(Utils.IS_FROM_DAPPS, false);
            mRestartSetupAction =
                    getIntent().getBooleanExtra(Utils.RESTART_WALLET_ACTIVITY_SETUP, false);
            mRestartRestoreAction =
                    getIntent().getBooleanExtra(Utils.RESTART_WALLET_ACTIVITY_RESTORE, false);
        }
        mShowBiometricPrompt = true;
        mToolbar = findViewById(R.id.toolbar);
        mToolbar.setTitleTextColor(getResources().getColor(android.R.color.black));
        mToolbar.setTitle("");
        mToolbar.setOverflowIcon(
                ContextCompat.getDrawable(this, R.drawable.ic_baseline_more_vert_24));
        setSupportActionBar(mToolbar);

        mBuySendSwapButton = findViewById(R.id.buy_send_swap_button);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // For Android 7 and above use vector images for send/swap button.
            // For Android 5 and 6 it is a bitmap specified in activity_brave_wallet.xml.
            mBuySendSwapButton.setImageResource(R.drawable.ic_swap_icon);
            mBuySendSwapButton.setBackgroundResource(R.drawable.ic_swap_bg);
        }

        try {
            BraveActivity activity = BraveActivity.getBraveActivity();
            mWalletModel = activity.getWalletModel();
            // Set origin to null, to use default network in domain layer.
            mWalletModel.setOriginInfo(null);
        } catch (BraveActivity.BraveActivityNotFoundException e) {
            Log.e(TAG, "triggerLayoutInflation " + e);
        }

        mBuySendSwapButton.setOnClickListener(v -> {
            NetworkInfo ethNetwork = null;
            // Always show buy send swap with ETH
            if (mWalletModel != null) {
                ethNetwork = mWalletModel.getNetworkModel().getNetwork(
                        BraveWalletConstants.MAINNET_CHAIN_ID);
            }
            SwapBottomSheetDialogFragment swapBottomSheetDialogFragment =
                    SwapBottomSheetDialogFragment.newInstance();
            swapBottomSheetDialogFragment.setNetwork(ethNetwork);
            swapBottomSheetDialogFragment.show(
                    getSupportFragmentManager(), SwapBottomSheetDialogFragment.TAG_FRAGMENT);
        });

        mPendingTxNotification = findViewById(R.id.pending_tx_notification);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // For Android 7 and above use vector images for send/swap button.
            // For Android 5 and 6 it is a bitmap specified in activity_brave_wallet.xml.
            mPendingTxNotification.setImageResource(R.drawable.ic_pending_tx_notification_icon);
            mPendingTxNotification.setBackgroundResource(R.drawable.ic_pending_tx_notification_bg);
        }

        mPendingTxNotification.setOnClickListener(v -> {
            PortfolioFragment portfolioFragment =
                    mCryptoFragmentPageAdapter.getCurrentPortfolioFragment();
            if (portfolioFragment != null) portfolioFragment.callAnotherApproveDialog();
        });
        mCryptoLayout = findViewById(R.id.crypto_layout);
        mCryptoOnboardingLayout = findViewById(R.id.crypto_onboarding_layout);
        mCryptoWalletOnboardingViewPager = findViewById(R.id.crypto_wallet_onboarding_viewpager);
        mCryptoWalletOnboardingPagerAdapter =
                new CryptoWalletOnboardingPagerAdapter(getSupportFragmentManager());
        mCryptoWalletOnboardingViewPager.setAdapter(mCryptoWalletOnboardingPagerAdapter);
        mCryptoWalletOnboardingViewPager.setOffscreenPageLimit(
                mCryptoWalletOnboardingPagerAdapter.getCount() - 1);

        ImageView onboardingBackButton = findViewById(R.id.onboarding_back_button);
        onboardingBackButton.setVisibility(View.GONE);
        onboardingBackButton.setOnClickListener(v -> {
            if (mCryptoWalletOnboardingViewPager != null) {
                mCryptoWalletOnboardingViewPager.setCurrentItem(
                        mCryptoWalletOnboardingViewPager.getCurrentItem() - 1);
            }
        });

        mCryptoWalletOnboardingViewPager.addOnPageChangeListener(
                new ViewPager.OnPageChangeListener() {
                    @Override
                    public void onPageScrolled(
                            int position, float positionOffset, int positionOffsetPixels) {}

                    @Override
                    public void onPageSelected(int position) {
                        if (position == 0 || position == 2) {
                            onboardingBackButton.setVisibility(View.GONE);
                        } else {
                            onboardingBackButton.setVisibility(View.VISIBLE);
                        }
                    }

                    @Override
                    public void onPageScrollStateChanged(int state) {}
                });

        mModalDialogManager = new ModalDialogManager(
                new AppModalPresenter(this), ModalDialogManager.ModalDialogType.APP);

        onInitialLayoutInflationComplete();
    }

    @Override
    public void finishNativeInitialization() {
        super.finishNativeInitialization();
        if (Utils.shouldShowCryptoOnboarding()) {
            setNavigationFragments(ONBOARDING_FIRST_PAGE_ACTION);
        } else if (mKeyringService != null) {
            mKeyringService.isLocked(isLocked -> {
                if (isLocked) {
                    setNavigationFragments(UNLOCK_WALLET_ACTION);
                } else {
                    setCryptoLayout();
                }
            });
        }
    }

    @Override
    public void onDestroy() {
        mModalDialogManager.destroy();
        super.onDestroy();
    }

    @Override
    protected ActivityWindowAndroid createWindowAndroid() {
        return new ActivityWindowAndroid(this, true, getIntentRequestTracker()) {
            @Override
            public ModalDialogManager getModalDialogManager() {
                return mModalDialogManager;
            }
        };
    }

    private void setNavigationFragments(int type) {
        List<NavigationItem> navigationItems = new ArrayList<>();
        mShowBiometricPrompt = true;
        mCryptoLayout.setVisibility(View.GONE);
        mPendingTxNotification.setVisibility(View.GONE);
        mBuySendSwapButton.setVisibility(View.GONE);
        mCryptoOnboardingLayout.setVisibility(View.VISIBLE);
        if (type == ONBOARDING_FIRST_PAGE_ACTION) {
            SetupWalletFragment setupWalletFragment =
                    new SetupWalletFragment(mRestartSetupAction, mRestartRestoreAction);
            setupWalletFragment.setOnNextPageListener(this);
            navigationItems.add(new NavigationItem(
                    getResources().getString(R.string.setup_crypto), setupWalletFragment));
            mBraveWalletP3A.reportOnboardingAction(OnboardingAction.SHOWN);
        } else if (type == UNLOCK_WALLET_ACTION) {
            UnlockWalletFragment unlockWalletFragment = new UnlockWalletFragment();
            unlockWalletFragment.setOnNextPageListener(this);
            navigationItems.add(new NavigationItem(
                    getResources().getString(R.string.unlock_wallet_title), unlockWalletFragment));
        } else if (type == RESTORE_WALLET_ACTION) {
            mShowBiometricPrompt = false;
            RestoreWalletFragment restoreWalletFragment = RestoreWalletFragment.newInstance(false);
            restoreWalletFragment.setOnNextPageListener(this);
            navigationItems.add(
                    new NavigationItem(getResources().getString(R.string.restore_crypto_account),
                            restoreWalletFragment));
        }

        if (mCryptoWalletOnboardingPagerAdapter != null) {
            mCryptoWalletOnboardingPagerAdapter.setNavigationItems(navigationItems);
            mCryptoWalletOnboardingPagerAdapter.notifyDataSetChanged();
        }
        addRemoveSecureFlag(true);
    }

    private void addRemoveSecureFlag(boolean add) {
        if (add) {
            getWindow().setFlags(
                    WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE);
        } else {
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
        }
        try {
            getWindowManager().removeViewImmediate(getWindow().getDecorView());
            getWindowManager().addView(getWindow().getDecorView(), getWindow().getAttributes());
        } catch (IllegalArgumentException exc) {
            // The activity isn't active right now
        }
    }

    private void replaceNavigationFragments(int type, boolean doNavigate, boolean isOnboarding) {
        mShowBiometricPrompt = true;
        if (mCryptoWalletOnboardingViewPager != null
                && mCryptoWalletOnboardingPagerAdapter != null) {
            if (type == RESTORE_WALLET_ACTION) {
                mShowBiometricPrompt = false;
                RestoreWalletFragment restoreWalletFragment =
                        RestoreWalletFragment.newInstance(isOnboarding);
                restoreWalletFragment.setOnNextPageListener(this);
                mCryptoWalletOnboardingPagerAdapter.replaceWithNavigationItem(
                        new NavigationItem(
                                getResources().getString(R.string.restore_crypto_account),
                                restoreWalletFragment),
                        mCryptoWalletOnboardingViewPager.getCurrentItem() + 1);
            } else if (type == ONBOARDING_ACTION) {
                List<NavigationItem> navigationItems = new ArrayList<>();
                SecurePasswordFragment securePasswordFragment = new SecurePasswordFragment();
                securePasswordFragment.setOnNextPageListener(this);
                navigationItems.add(
                        new NavigationItem(getResources().getString(R.string.secure_your_crypto),
                                securePasswordFragment));
                addBackupWalletSequence(navigationItems, true);
                mCryptoWalletOnboardingPagerAdapter.replaceWithNavigationItems(
                        navigationItems, mCryptoWalletOnboardingViewPager.getCurrentItem() + 1);
            }

            mCryptoWalletOnboardingPagerAdapter.notifyDataSetChanged();

            if (doNavigate) {
                mCryptoWalletOnboardingViewPager.setCurrentItem(
                        mCryptoWalletOnboardingViewPager.getCurrentItem() + 1);
            }
        }
    }

    private void setCryptoLayout() {
        addRemoveSecureFlag(false);

        mCryptoOnboardingLayout.setVisibility(View.GONE);
        mCryptoLayout.setVisibility(View.VISIBLE);

        ViewPager viewPager = findViewById(R.id.navigation_view_pager);
        mCryptoFragmentPageAdapter =
                new CryptoFragmentPageAdapter(getSupportFragmentManager(), this);
        viewPager.setAdapter(mCryptoFragmentPageAdapter);
        viewPager.setOffscreenPageLimit(mCryptoFragmentPageAdapter.getCount() - 1);
        TabLayout tabLayout = findViewById(R.id.tabs);
        tabLayout.setupWithViewPager(viewPager);

        if (mBuySendSwapButton != null) mBuySendSwapButton.setVisibility(View.VISIBLE);

        if (mKeyringService != null) {
            mKeyringService.isWalletBackedUp(backed_up -> {
                if (!backed_up) {
                    showWalletBackupBanner();
                } else {
                    findViewById(R.id.wallet_backup_banner).setVisibility(View.GONE);
                }
            });
        }
    }

    private void addBackupWalletSequence(
            List<NavigationItem> navigationItems, boolean isOnboarding) {
        BackupWalletFragment backupWalletFragment = BackupWalletFragment.newInstance(isOnboarding);
        backupWalletFragment.setOnNextPageListener(this);
        navigationItems.add(new NavigationItem(
                getResources().getString(R.string.backup_your_wallet), backupWalletFragment));
        RecoveryPhraseFragment recoveryPhraseFragment =
                RecoveryPhraseFragment.newInstance(isOnboarding);
        recoveryPhraseFragment.setOnNextPageListener(this);
        navigationItems.add(new NavigationItem(
                getResources().getString(R.string.your_recovery_phrase), recoveryPhraseFragment));
        VerifyRecoveryPhraseFragment verifyRecoveryPhraseFragment =
                VerifyRecoveryPhraseFragment.newInstance(isOnboarding);
        verifyRecoveryPhraseFragment.setOnNextPageListener(this);
        navigationItems.add(
                new NavigationItem(getResources().getString(R.string.verify_recovery_phrase),
                        verifyRecoveryPhraseFragment));
    }

    public void backupBannerOnClick() {
        addRemoveSecureFlag(true);
        mCryptoOnboardingLayout.setVisibility(View.VISIBLE);
        mCryptoLayout.setVisibility(View.GONE);
        mPendingTxNotification.setVisibility(View.GONE);
        mBuySendSwapButton.setVisibility(View.GONE);

        List<NavigationItem> navigationItems = new ArrayList<>();
        addBackupWalletSequence(navigationItems, false);

        if (mCryptoWalletOnboardingPagerAdapter != null
                && mCryptoWalletOnboardingViewPager != null) {
            mCryptoWalletOnboardingPagerAdapter.setNavigationItems(navigationItems);
            mCryptoWalletOnboardingPagerAdapter.notifyDataSetChanged();
            mCryptoWalletOnboardingViewPager.setCurrentItem(0);
        }
    }

    private void showWalletBackupBanner() {
        final ViewGroup backupTopBannerLayout = (ViewGroup) findViewById(R.id.wallet_backup_banner);
        backupTopBannerLayout.setVisibility(View.VISIBLE);
        backupTopBannerLayout.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                backupBannerOnClick();
            }
        });
        ImageView bannerClose = backupTopBannerLayout.findViewById(R.id.backup_banner_close);
        bannerClose.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                backupTopBannerLayout.setVisibility(View.GONE);
            }
        });
    }

    public void setPendingTxNotificationVisibility(int visibility) {
        mPendingTxNotification.setVisibility(visibility);
    }

    @Override
    public boolean showBiometricPrompt() {
        int state = ApplicationStatus.getStateForActivity(this);

        return mShowBiometricPrompt
                && (state != ActivityState.PAUSED || state != ActivityState.STOPPED
                        || state != ActivityState.DESTROYED);
    }

    @Override
    public void showBiometricPrompt(boolean show) {
        mShowBiometricPrompt = show;
    }

    @Override
    public void gotoNextPage(boolean finishOnboarding) {
        if (finishOnboarding) {
            if (mIsFromDapps) {
                finish();
                try {
                    BraveActivity activity = BraveActivity.getBraveActivity();
                    activity.showWalletPanel(true);
                } catch (BraveActivity.BraveActivityNotFoundException e) {
                    Log.e(TAG, "gotoNextPage " + e);
                }
                return;
            }
            setCryptoLayout();
        } else {
            if (mCryptoWalletOnboardingViewPager != null) {
                mCryptoWalletOnboardingViewPager.setCurrentItem(
                        mCryptoWalletOnboardingViewPager.getCurrentItem() + 1);
            }
        }
    }

    @Override
    public void gotoOnboardingPage() {
        replaceNavigationFragments(ONBOARDING_ACTION, true, true);
        mBraveWalletP3A.reportOnboardingAction(OnboardingAction.LEGAL_AND_PASSWORD);
    }

    @Override
    public void gotoRestorePage(boolean isOnboarding) {
        replaceNavigationFragments(RESTORE_WALLET_ACTION, true, isOnboarding);
        if (isOnboarding) {
            mBraveWalletP3A.reportOnboardingAction(OnboardingAction.START_RESTORE);
        }
    }

    @Override
    public void locked() {
        setNavigationFragments(UNLOCK_WALLET_ACTION);
    }

    @Override
    public void backedUp() {
        findViewById(R.id.wallet_backup_banner).setVisibility(View.GONE);
    }
}
