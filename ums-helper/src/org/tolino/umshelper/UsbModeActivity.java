package org.tolino.umshelper;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.view.Window;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * The full-screen screen shown while the reader's storage is shared with the computer - what the
 * stock Tolino app used to display.
 *
 * <p>Mass storage removes /storage/sdcard1 from Android, so KOReader cannot be in the foreground
 * during that time. This activity touches no storage at all.
 *
 * <p>Four things this class has to get right, each learned the hard way:
 *
 * <ul>
 *   <li>The mode is passed explicitly by {@link UmsReceiver} rather than inferred from the volume
 *       state, because sharing is asynchronous - checking right after requesting the share sees
 *       "mounted" and hands straight back to KOReader.
 *   <li>Because the activity is {@code singleTask}, a second start delivers {@link #onNewIntent},
 *       not {@link #onCreate}. Handling only onCreate left the screen stuck on "USB connected".
 *   <li>KOReader is stopped <em>before</em> the volume is shared. Otherwise its FileProvider
 *       crashes on the vanished storage and the system puts an error panel over this screen.
 *   <li>On the way back, KOReader is only started once storage is genuinely usable. vold
 *       reporting the volume "mounted" is not enough - starting at that instant still crashes
 *       KOReader with {@code Invalid mkdirs path}. Rather than guess a delay, this polls
 *       {@code getExternalFilesDirs()} - the very call that fails - and starts KOReader the moment
 *       it succeeds.
 * </ul>
 */
public class UsbModeActivity extends Activity {

    private static final String TAG = "UmsHelper";
    private static final String KOREADER_PKG = "org.koreader.launcher";
    private static final String KOREADER_ACTIVITY = "org.koreader.launcher.MainActivity";
    private static final String VOLUME_PATH = "/storage/sdcard1";

    static final String EXTRA_MODE = "mode";
    static final String MODE_CONNECT = "connect";
    static final String MODE_DISCONNECT = "disconnect";

    private static final int POLL_MS = 300;
    private static final int POLL_MAX = 100;             // ~30s hard ceiling
    private static final int UNSHARE_MAX = 40;           // ~12s waiting for the unshare

    private final Handler handler = new Handler();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        goFullscreen();
        handleIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handler.removeCallbacksAndMessages(null);
        handleIntent(intent);
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    /** No title bar, no status bar - the whole e-ink panel belongs to this screen. */
    private void goFullscreen() {
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN);
        getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.WHITE));
    }

    private void handleIntent(Intent intent) {
        String mode = (intent == null) ? null : intent.getStringExtra(EXTRA_MODE);
        Log.i(TAG, "handleIntent mode=" + mode);

        if (MODE_DISCONNECT.equals(mode)) {
            setContentView(buildScreen(
                    BadgeView.GLYPH_RETURN,
                    "Disconnecting",
                    "Your library is on its way back.\nKOReader will open in a moment."));
            MountService.setEnabled(false);              // idempotent
            waitForUnshare(0);
        } else {
            setContentView(buildScreen(
                    BadgeView.GLYPH_TRANSFER,
                    "USB storage connected",
                    "Your library is shared with your computer.\n\n"
                    + "Copy your books across, then unplug the cable to keep reading."));

            // We are foreground now, so KOReader is backgrounded. Stop it before the volume goes
            // away, otherwise it crashes and the system raises an error panel over this screen.
            stopKoreader();

            // Let this screen appear before the share unmounts the volume.
            handler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    MountService.setEnabled(true);
                }
            }, 1200);
        }
    }

    private void stopKoreader() {
        try {
            android.app.ActivityManager am =
                    (android.app.ActivityManager) getSystemService(ACTIVITY_SERVICE);
            if (am == null) {
                return;
            }
            am.killBackgroundProcesses(KOREADER_PKG);
            Log.i(TAG, "asked ActivityManager to stop KOReader");
        } catch (Throwable t) {
            Log.e(TAG, "could not stop KOReader: " + t, t);
        }
    }

    // ------------------------------------------------------- coming back from USB mode

    private void waitForUnshare(final int attempt) {
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (!MountService.isVolumeShared()) {
                    Log.i(TAG, "volume released after " + attempt + " checks");
                    awaitStorageReady(0);
                    return;
                }

                // Still shared. vold refuses to release a LUN the host is holding (it reports
                // "Device or resource busy"), which is what happens if the cable is still in or
                // the computer is browsing the reader. Re-request periodically and keep waiting -
                // KOReader must not be started while its storage belongs to the PC.
                if (attempt % 10 == 0) {
                    Log.i(TAG, "still shared after " + attempt + " checks - re-requesting release");
                    MountService.setEnabled(false);
                }
                if (attempt == UNSHARE_MAX) {
                    setContentView(buildScreen(
                            BadgeView.GLYPH_RETURN,
                            "Storage still in use",
                            "Your computer is still using the reader's storage.\n\n"
                            + "Unplug the USB cable, or close anything on the computer "
                            + "that is browsing the reader."));
                }
                waitForUnshare(attempt + 1);
            }
        }, POLL_MS);
    }

    /**
     * Wait until the volume is genuinely usable before starting KOReader.
     *
     * <p>The volume state is the authoritative check: getExternalFilesDirs() alone is not enough,
     * because it can succeed from an existing directory even while the volume is shared. Waiting on
     * it without that gate is how an earlier build managed to start KOReader into a missing volume.
     */
    private void awaitStorageReady(final int attempt) {
        if (!MountService.isVolumeShared() && storageReady()) {
            Log.i(TAG, "storage usable after " + attempt + " probes - starting KOReader");
            launchKoreader();
            finish();
            return;
        }
        if (attempt >= POLL_MAX) {
            Log.w(TAG, "storage never became usable - staying put rather than crashing KOReader");
            setContentView(buildScreen(
                    BadgeView.GLYPH_RETURN,
                    "Storage unavailable",
                    "The reader's library has not come back yet.\n\n"
                    + "Unplug and replug the cable to try again."));
            return;
        }
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                awaitStorageReady(attempt + 1);
            }
        }, POLL_MS);
    }

    private boolean storageReady() {
        try {
            java.io.File[] dirs = getExternalFilesDirs(null);
            return dirs != null && dirs.length > 0 && dirs[0] != null;
        } catch (Throwable t) {
            return false;                    // volume not ready yet - exactly the old crash
        }
    }

    private void launchKoreader() {
        try {
            Intent intent = new Intent(Intent.ACTION_MAIN);
            intent.addCategory(Intent.CATEGORY_LAUNCHER);
            intent.setComponent(new ComponentName(KOREADER_PKG, KOREADER_ACTIVITY));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
            startActivity(intent);
            Log.i(TAG, "launched KOReader");
        } catch (Throwable t) {
            Log.e(TAG, "could not launch KOReader: " + t, t);
        }
    }

    // ---------------------------------------------------------------- layout

    private int dp(float value) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value,
                getResources().getDisplayMetrics());
    }

    /**
     * A fixed-geometry card on white.
     *
     * <p>Every element sits at a fixed position and the card itself is a fixed size, so switching
     * between the connected and disconnecting states changes only the glyph and the words - nothing
     * moves. Content-sized layouts made the shorter screen smaller, which shifted the badge and
     * heading when the cable came out.
     *
     * <p>E-ink is greyscale and slow to refresh, so: large type, generous spacing, no animation.
     */
    private View buildScreen(int glyph, String title, String body) {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.WHITE);

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(dp(44), dp(56), dp(44), dp(40));

        // 1. badge - fixed square, horizontally centred by the card's gravity
        BadgeView badge = new BadgeView(this, glyph);
        LinearLayout.LayoutParams badgeParams = new LinearLayout.LayoutParams(dp(104), dp(104));
        badgeParams.bottomMargin = dp(30);
        card.addView(badge, badgeParams);

        // 2. heading - fixed height, so a longer or shorter title cannot move anything below it
        TextView titleView = new TextView(this);
        titleView.setText(title);
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 34f);
        titleView.setTextColor(Color.parseColor("#111111"));
        titleView.setGravity(Gravity.CENTER);
        titleView.setTypeface(titleView.getTypeface(), android.graphics.Typeface.BOLD);
        card.addView(titleView, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(54)));

        // 3. rule - fixed
        View rule = new View(this);
        rule.setBackgroundColor(Color.parseColor("#C8C8C8"));
        LinearLayout.LayoutParams ruleParams = new LinearLayout.LayoutParams(dp(140), dp(1));
        ruleParams.topMargin = dp(22);
        ruleParams.bottomMargin = dp(28);
        card.addView(rule, ruleParams);

        // 4. body - fixed height box, top aligned so the first line never drifts
        TextView bodyView = new TextView(this);
        bodyView.setText(body);
        bodyView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 21f);
        bodyView.setTextColor(Color.parseColor("#333333"));
        bodyView.setGravity(Gravity.CENTER_HORIZONTAL | Gravity.TOP);
        bodyView.setLineSpacing(dp(8), 1f);
        card.addView(bodyView, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(230)));

        FrameLayout.LayoutParams cardParams =
                new FrameLayout.LayoutParams(dp(500), dp(560));
        cardParams.gravity = Gravity.CENTER;
        root.addView(card, cardParams);
        return root;
    }

    /** While storage is shared there is nowhere useful to go back to. */
    @Override
    public void onBackPressed() {
        Log.i(TAG, "back ignored while in USB mode");
    }
}
