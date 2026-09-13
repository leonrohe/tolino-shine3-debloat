package org.tolino.umshelper;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Reacts to the USB mass-storage connection changing.
 *
 * <p>Only the two explicit UMS transitions are handled. The sticky
 * {@code android.hardware.usb.action.USB_STATE} broadcast is deliberately NOT used: sticky
 * broadcasts are replayed to a receiver the moment it registers, which is during boot, and an
 * earlier version of this app therefore shared the storage before KOReader could start - leaving
 * KOReader crash-looping and the device with a home app that could not run.
 */
public class UmsReceiver extends BroadcastReceiver {

    private static final String TAG = "UmsHelper";

    private static final String ACTION_CONNECTED = "android.intent.action.UMS_CONNECTED";
    private static final String ACTION_DISCONNECTED = "android.intent.action.UMS_DISCONNECTED";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = (intent == null) ? null : intent.getAction();
        Log.i(TAG, "onReceive action=" + action);
        if (context == null || action == null) {
            return;
        }

        if (ACTION_CONNECTED.equals(action)) {
            // The activity brings itself to the front, stops KOReader, and only then shares the
            // volume (see UsbModeActivity). Sharing here instead would race the activity and leave
            // KOReader crashing on a storage volume that has just vanished.
            startUsbScreen(context, UsbModeActivity.MODE_CONNECT);
        } else if (ACTION_DISCONNECTED.equals(action)) {
            // Release the volume, then let the activity wait for the remount and relaunch KOReader.
            // Doing the wait inside an activity keeps a process alive to finish the job.
            MountService.setEnabled(false);
            startUsbScreen(context, UsbModeActivity.MODE_DISCONNECT);
        }
    }

    private static void startUsbScreen(Context context, String mode) {
        try {
            Intent intent = new Intent(context, UsbModeActivity.class);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP
                    | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            intent.putExtra(UsbModeActivity.EXTRA_MODE, mode);
            context.startActivity(intent);
            Log.i(TAG, "started UsbModeActivity mode=" + mode);
        } catch (Throwable t) {
            Log.e(TAG, "could not start UsbModeActivity: " + t, t);
        }
    }
}
