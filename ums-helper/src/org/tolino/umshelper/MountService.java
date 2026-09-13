package org.tolino.umshelper;

import android.os.IBinder;
import android.util.Log;

import java.lang.reflect.Method;

/**
 * Talks to MountService over Binder.
 *
 * <p>{@code StorageManager.setUsbMassStorageEnabled()} does not exist on this ROM - KitKat removed
 * it when UMS was deprecated - so the capability is reached at the Binder interface instead:
 * {@code IMountService.setUsbMassStorageEnabled(boolean)}.
 *
 * <p>Requires MOUNT_UNMOUNT_FILESYSTEMS, which this app holds because it is a system app and the
 * declaration in framework-res.apk was loosened to "normal".
 */
final class MountService {

    private static final String TAG = "UmsHelper";
    private static final String SERVICE = "mount";
    private static final String IFACE = "android.os.storage.IMountService";
    private static final String STUB = "android.os.storage.IMountService$Stub";

    private MountService() {
    }

    private static Object service() throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) sm.getMethod("getService", String.class).invoke(null, SERVICE);
        if (binder == null) {
            return null;
        }
        Class<?> stub = Class.forName(STUB);
        return stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    static boolean setEnabled(boolean enable) {
        try {
            Object svc = service();
            if (svc == null) {
                Log.w(TAG, "mount service unavailable");
                return false;
            }
            Class<?> iface = Class.forName(IFACE);
            Method setter = iface.getMethod("setUsbMassStorageEnabled", boolean.class);
            setter.invoke(svc, enable);
            Log.i(TAG, "setUsbMassStorageEnabled(" + enable + ") ok");
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "setUsbMassStorageEnabled(" + enable + ") failed: " + t, t);
            return false;
        }
    }

    /** Whether vold currently has the volume shared. This is what actually matters. */
    static boolean isVolumeShared() {
        try {
            Object svc = service();
            if (svc == null) {
                return false;
            }
            Class<?> iface = Class.forName(IFACE);
            Method getter = iface.getMethod("getVolumeState", String.class);
            Object state = getter.invoke(svc, "/storage/sdcard1");
            Log.i(TAG, "getVolumeState(/storage/sdcard1) = " + state);
            return "shared".equals(String.valueOf(state));
        } catch (Throwable t) {
            Log.e(TAG, "getVolumeState failed: " + t, t);
            return false;
        }
    }
}
