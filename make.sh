#!/bin/bash
set -e
mkdir -p '.'
cat > 'build.gradle' <<'FLOATY_EOF'
plugins {
    id 'com.android.application' version '8.5.2' apply false
}
FLOATY_EOF
mkdir -p '.'
cat > 'gradle.properties' <<'FLOATY_EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.nonTransitiveRClass=true
FLOATY_EOF
mkdir -p '.'
cat > 'settings.gradle' <<'FLOATY_EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "Floaty"
include ':app'
FLOATY_EOF
mkdir -p 'app'
cat > 'app/build.gradle' <<'FLOATY_EOF'
plugins {
    id 'com.android.application'
}

android {
    namespace 'com.floaty.timer'
    compileSdk 34

    defaultConfig {
        applicationId 'com.floaty.timer'
        minSdk 26
        targetSdk 34
        versionCode 1
        versionName '1.0'
    }

    buildTypes {
        release {
            minifyEnabled false
        }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
}
FLOATY_EOF
mkdir -p 'app/src/main'
cat > 'app/src/main/AndroidManifest.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />

    <application
        android:allowBackup="false"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:theme="@android:style/Theme.DeviceDefault.NoActionBar">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".FloatingService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="floating_timer_overlay" />
        </service>
    </application>
</manifest>
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/BubbleView.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.view.View;

/** The floating bubble. Draws the shape, the time, a small label and a progress ring/bar. */
class BubbleView extends View {
    int shape = Prefs.SHAPE_CIRCLE;
    int font = Prefs.FONT_REGULAR;
    boolean ring = true;
    int bg = 0xFF14161C;
    int fg = 0xFFFFFFFF;
    int accent = 0xFF7C9CFF;
    int opacityPct = 95;
    int sizeDp = 110;

    String text = "00:00";
    String label = null;
    float progress = -1f;
    int ringColor = 0;
    boolean highlight = false;

    private final float density;
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint outline = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint arc = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint mainText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint labelText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF r = new RectF();
    private final RectF r2 = new RectF();

    BubbleView(Context c) {
        super(c);
        density = c.getResources().getDisplayMetrics().density;
        fill.setStyle(Paint.Style.FILL);
        outline.setStyle(Paint.Style.STROKE);
        outline.setStrokeWidth(density);
        arc.setStyle(Paint.Style.STROKE);
        arc.setStrokeCap(Paint.Cap.ROUND);
        mainText.setTextAlign(Paint.Align.CENTER);
        mainText.setFontFeatureSettings("tnum");
        labelText.setTextAlign(Paint.Align.CENTER);
        labelText.setLetterSpacing(0.12f);
        labelText.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        updateTypeface();
    }

    void applyPrefs(SharedPreferences p) {
        shape = Prefs.getInt(p, Prefs.SHAPE);
        font = Prefs.getInt(p, Prefs.FONT);
        ring = Prefs.getInt(p, Prefs.RING) == 1;
        sizeDp = Prefs.getInt(p, Prefs.SIZE);
        opacityPct = Prefs.getInt(p, Prefs.OPACITY);
        bg = Prefs.getInt(p, Prefs.BG);
        fg = Prefs.getInt(p, Prefs.FG);
        accent = Prefs.getInt(p, Prefs.ACCENT);
        updateTypeface();
        requestLayout();
        invalidate();
    }

    void setState(String t, String l, float p, int rc, boolean hl) {
        text = t;
        label = l;
        progress = p;
        ringColor = rc;
        highlight = hl;
        invalidate();
    }

    int widthPx() {
        float f = shape == Prefs.SHAPE_PILL ? 1.7f : 1f;
        return Math.round(sizeDp * density * f);
    }

    int heightPx() {
        float f = shape == Prefs.SHAPE_PILL ? 0.7f : 1f;
        return Math.round(sizeDp * density * f);
    }

    private void updateTypeface() {
        Typeface tf;
        if (font == Prefs.FONT_LIGHT) {
            tf = Typeface.create("sans-serif-light", Typeface.NORMAL);
        } else if (font == Prefs.FONT_BOLD) {
            tf = Typeface.create("sans-serif", Typeface.BOLD);
        } else if (font == Prefs.FONT_MONO) {
            tf = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL);
        } else {
            tf = Typeface.create("sans-serif", Typeface.NORMAL);
        }
        mainText.setTypeface(tf);
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        setMeasuredDimension(widthPx(), heightPx());
    }

    static int withAlpha(int color, int alpha) {
        return (color & 0x00FFFFFF) | (alpha << 24);
    }

    private static float clamp01(float v) {
        if (v < 0f) return 0f;
        if (v > 1f) return 1f;
        return v;
    }

    private void drawShape(Canvas c, RectF rect, Paint p, float w, float h) {
        if (shape == Prefs.SHAPE_CIRCLE) {
            c.drawOval(rect, p);
        } else if (shape == Prefs.SHAPE_SQUIRCLE) {
            float rad = Math.min(w, h) * 0.30f;
            c.drawRoundRect(rect, rad, rad, p);
        } else {
            float rad = h / 2f;
            c.drawRoundRect(rect, rad, rad, p);
        }
    }

    @Override
    protected void onDraw(Canvas c) {
        float w = getWidth();
        float h = getHeight();
        if (w <= 0f || h <= 0f) return;

        int a = Math.round(255f * opacityPct / 100f);
        int body = highlight ? accent : bg;
        int ink = highlight ? bg : fg;
        int accentC = ringColor != 0 ? ringColor : accent;
        if (highlight) accentC = bg;

        r.set(density, density, w - density, h - density);
        fill.setColor(withAlpha(body, a));
        drawShape(c, r, fill, w, h);
        outline.setColor(withAlpha(ink, Math.min(a, 38)));
        drawShape(c, r, outline, w, h);

        boolean circle = shape == Prefs.SHAPE_CIRCLE;
        boolean pill = shape == Prefs.SHAPE_PILL;
        boolean showProgress = ring && progress >= 0f;
        boolean ringOn = showProgress && circle;
        boolean barOn = showProgress && !circle;
        boolean hasLabel = label != null && !pill;

        float base = pill ? h * 0.42f : h * 0.27f;
        float avail = circle ? w * (ringOn ? 0.60f : 0.74f) : w * 0.78f;
        mainText.setColor(ink);
        mainText.setTextSize(base);
        float mw = mainText.measureText(text);
        if (mw > avail) mainText.setTextSize(base * avail / mw);
        float ms = mainText.getTextSize();

        if (ringOn) {
            float sw = w * 0.05f;
            float pad = w * 0.075f;
            arc.setStrokeWidth(sw);
            r2.set(pad, pad, w - pad, h - pad);
            arc.setColor(withAlpha(ink, 40));
            c.drawOval(r2, arc);
            arc.setColor(accentC);
            c.drawArc(r2, -90f, 360f * clamp01(progress), false, arc);
        }

        float cyMain = hasLabel ? h * 0.45f : h * 0.5f;
        if (barOn) cyMain = hasLabel ? h * 0.40f : h * 0.45f;
        float baseline = cyMain + ms * 0.36f;
        c.drawText(text, w / 2f, baseline, mainText);

        if (hasLabel) {
            float ls = ms * 0.36f;
            labelText.setTextSize(ls);
            labelText.setColor(accentC);
            c.drawText(label, w / 2f, baseline + ls * 1.45f, labelText);
        }

        if (barOn) {
            float bw = w * 0.5f;
            float bh = Math.max(2f * density, h * 0.045f);
            float by = h * (pill ? 0.78f : 0.84f);
            float left = (w - bw) / 2f;
            r2.set(left, by, left + bw, by + bh);
            fill.setColor(withAlpha(ink, 40));
            c.drawRoundRect(r2, bh / 2f, bh / 2f, fill);
            r2.set(left, by, left + bw * clamp01(progress), by + bh);
            fill.setColor(accentC);
            c.drawRoundRect(r2, bh / 2f, bh / 2f, fill);
        }
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/FloatingService.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.Icon;
import android.media.AudioAttributes;
import android.media.Ringtone;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.WindowManager;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** Foreground service that owns the floating bubble and all timer logic. */
public class FloatingService extends Service {
    static final String ACTION_STOP = "com.floaty.timer.STOP";
    static final String ACTION_REFRESH = "com.floaty.timer.REFRESH";
    static final String ACTION_CONFIG = "com.floaty.timer.CONFIG";

    /** True while the service (and its bubble) exists. */
    static volatile boolean active = false;

    private static final String CHANNEL = "floaty_timer";
    private static final int NOTIF_ID = 1;
    private static final int PHASE_WORK = 0;
    private static final int PHASE_SHORT = 1;
    private static final int PHASE_LONG = 2;
    private static final int BREAK_COLOR = 0xFF5BD6A0;

    private WindowManager wm;
    private SharedPreferences prefs;
    private Vibrator vibrator;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private BubbleView bubble;
    private WindowManager.LayoutParams bubbleLp;
    private TextView trash;
    private WindowManager.LayoutParams trashLp;

    private Ringtone ringtone;
    private final Runnable stopSoundRunnable = this::stopAlarmSound;

    // ---- timer state ----
    private int mode;
    private boolean clock24;
    private boolean clockSec;
    private boolean timerRunning;
    private long baseElapsed;
    private long accumulatedMs;
    private long totalMs;
    private int phase;
    private int round;
    private int roundsBeforeLong;
    private boolean alarming;

    // ---- touch state ----
    private float downX;
    private float downY;
    private int startX;
    private int startY;
    private boolean moved;
    private boolean longPressed;
    private int touchSlop;
    private final Runnable longPress = new Runnable() {
        @Override
        public void run() {
            if (!moved) {
                longPressed = true;
                onLongPress();
            }
        }
    };

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            update();
            long delay = (timerRunning || mode == Prefs.MODE_CLOCK || alarming) ? 200L : 500L;
            handler.postDelayed(this, delay);
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        active = true;
        prefs = Prefs.get(this);
        wm = (WindowManager) getSystemService(WINDOW_SERVICE);
        vibrator = (Vibrator) getSystemService(VIBRATOR_SERVICE);
        touchSlop = ViewConfiguration.get(this).getScaledTouchSlop();
        startAsForeground();
        createBubble();
        loadConfig();
        handler.post(tick);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String a = intent == null ? null : intent.getAction();
        if (ACTION_STOP.equals(a)) {
            stopSelf();
        } else if (ACTION_REFRESH.equals(a)) {
            applyStyle();
            readClockFlags();
        } else if (ACTION_CONFIG.equals(a)) {
            applyStyle();
            loadConfig();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(tick);
        handler.removeCallbacks(longPress);
        handler.removeCallbacks(stopSoundRunnable);
        stopAlarmSound();
        hideTrash();
        try {
            if (bubble != null) wm.removeView(bubble);
        } catch (Exception ignored) {
        }
        bubble = null;
        active = false;
        super.onDestroy();
    }

    // ------------------------------------------------------------ foreground notification

    private void startAsForeground() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Floating timer",
                NotificationManager.IMPORTANCE_LOW));

        Intent open = new Intent(this, MainActivity.class);
        PendingIntent openPi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Intent stop = new Intent(this, FloatingService.class);
        stop.setAction(ACTION_STOP);
        PendingIntent stopPi = PendingIntent.getService(this, 1, stop,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Action stopAction = new Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                "Stop", stopPi).build();

        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle("Floaty is running")
                .setContentText("Tap to open settings")
                .setContentIntent(openPi)
                .addAction(stopAction)
                .setOngoing(true)
                .build();

        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }

    // ------------------------------------------------------------ bubble window

    private int dp(float v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private void createBubble() {
        bubble = new BubbleView(this);
        bubble.applyPrefs(prefs);

        bubbleLp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        bubbleLp.gravity = Gravity.TOP | Gravity.START;

        DisplayMetrics dm = getResources().getDisplayMetrics();
        int bw = bubble.widthPx();
        int bh = bubble.heightPx();
        int x = Prefs.getInt(prefs, Prefs.POS_X);
        int y = Prefs.getInt(prefs, Prefs.POS_Y);
        if (x < 0 || y < 0) {
            x = (dm.widthPixels - bw) / 2;
            y = dm.heightPixels / 5;
        }
        bubbleLp.x = Math.max(0, Math.min(x, dm.widthPixels - bw));
        bubbleLp.y = Math.max(0, Math.min(y, dm.heightPixels - bh));

        bubble.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent e) {
                int action = e.getActionMasked();
                if (action == MotionEvent.ACTION_DOWN) {
                    downX = e.getRawX();
                    downY = e.getRawY();
                    startX = bubbleLp.x;
                    startY = bubbleLp.y;
                    moved = false;
                    longPressed = false;
                    handler.postDelayed(longPress, 600L);
                    return true;
                }
                if (action == MotionEvent.ACTION_MOVE) {
                    float dx = e.getRawX() - downX;
                    float dy = e.getRawY() - downY;
                    if (!moved && Math.hypot(dx, dy) > touchSlop) {
                        moved = true;
                        handler.removeCallbacks(longPress);
                        showTrash();
                    }
                    if (moved) {
                        bubbleLp.x = (int) (startX + dx);
                        bubbleLp.y = (int) (startY + dy);
                        try {
                            wm.updateViewLayout(bubble, bubbleLp);
                        } catch (Exception ignored) {
                        }
                        updateTrashHover();
                    }
                    return true;
                }
                if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                    handler.removeCallbacks(longPress);
                    if (moved) {
                        boolean drop = action == MotionEvent.ACTION_UP && overTrash();
                        hideTrash();
                        if (drop) {
                            stopSelf();
                        } else {
                            prefs.edit()
                                    .putInt(Prefs.POS_X, bubbleLp.x)
                                    .putInt(Prefs.POS_Y, bubbleLp.y)
                                    .apply();
                        }
                    } else if (!longPressed && action == MotionEvent.ACTION_UP) {
                        onTap();
                    }
                    return true;
                }
                return false;
            }
        });

        wm.addView(bubble, bubbleLp);
    }

    private void applyStyle() {
        if (bubble == null) return;
        bubble.applyPrefs(prefs);
        try {
            wm.updateViewLayout(bubble, bubbleLp);
        } catch (Exception ignored) {
        }
        update();
    }

    private void showTrash() {
        if (trash != null) return;
        trash = new TextView(this);
        trash.setText("✕");
        trash.setTextColor(Color.WHITE);
        trash.setTextSize(22f);
        trash.setGravity(Gravity.CENTER);
        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.OVAL);
        gd.setColor(0xDD20232B);
        gd.setStroke(dp(1), 0x55FFFFFF);
        trash.setBackground(gd);
        trashLp = new WindowManager.LayoutParams(
                dp(64), dp(64),
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        trashLp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
        trashLp.y = dp(56);
        try {
            wm.addView(trash, trashLp);
        } catch (Exception e) {
            trash = null;
        }
    }

    private void hideTrash() {
        if (trash == null) return;
        try {
            wm.removeView(trash);
        } catch (Exception ignored) {
        }
        trash = null;
    }

    private boolean overTrash() {
        if (trash == null || trash.getWidth() == 0 || bubble == null) return false;
        int[] t = new int[2];
        trash.getLocationOnScreen(t);
        float tx = t[0] + trash.getWidth() / 2f;
        float ty = t[1] + trash.getHeight() / 2f;
        float bx = bubbleLp.x + bubble.getWidth() / 2f;
        float by = bubbleLp.y + bubble.getHeight() / 2f;
        float reach = trash.getWidth() / 2f + Math.min(bubble.getWidth(), bubble.getHeight()) * 0.3f;
        return Math.hypot(bx - tx, by - ty) < reach;
    }

    private void updateTrashHover() {
        if (trash == null) return;
        float s = overTrash() ? 1.25f : 1f;
        trash.setScaleX(s);
        trash.setScaleY(s);
    }

    // ------------------------------------------------------------ timer logic

    private void readClockFlags() {
        clock24 = Prefs.getInt(prefs, Prefs.CLOCK_24) == 1;
        clockSec = Prefs.getInt(prefs, Prefs.CLOCK_SEC) == 1;
    }

    private long phaseMs(int ph) {
        int minutes;
        if (ph == PHASE_WORK) {
            minutes = Prefs.getInt(prefs, Prefs.POMO_WORK);
        } else if (ph == PHASE_SHORT) {
            minutes = Prefs.getInt(prefs, Prefs.POMO_SHORT);
        } else {
            minutes = Prefs.getInt(prefs, Prefs.POMO_LONG);
        }
        return Math.max(1, minutes) * 60000L;
    }

    /** Re-read settings and start fresh (running). */
    private void loadConfig() {
        mode = Prefs.getInt(prefs, Prefs.MODE);
        readClockFlags();
        roundsBeforeLong = Math.max(1, Prefs.getInt(prefs, Prefs.POMO_ROUNDS));
        stopAlarm();
        resetState();
        timerRunning = mode != Prefs.MODE_CLOCK;
        baseElapsed = SystemClock.elapsedRealtime();
        update();
    }

    /** Back to the start, paused. */
    private void resetState() {
        accumulatedMs = 0L;
        timerRunning = false;
        alarming = false;
        phase = PHASE_WORK;
        round = 1;
        if (mode == Prefs.MODE_COUNTDOWN) {
            long ms = (Prefs.getInt(prefs, Prefs.CD_MIN) * 60L + Prefs.getInt(prefs, Prefs.CD_SEC)) * 1000L;
            totalMs = Math.max(1000L, ms);
        } else if (mode == Prefs.MODE_POMODORO) {
            totalMs = phaseMs(PHASE_WORK);
        } else {
            totalMs = 0L;
        }
    }

    private void toggleRun() {
        long now = SystemClock.elapsedRealtime();
        if (timerRunning) {
            accumulatedMs += now - baseElapsed;
            timerRunning = false;
        } else {
            baseElapsed = now;
            timerRunning = true;
        }
        update();
    }

    private void onTap() {
        if (alarming) {
            stopAlarm();
            resetState();
            update();
            return;
        }
        if (mode != Prefs.MODE_CLOCK) toggleRun();
    }

    private void onLongPress() {
        if (mode == Prefs.MODE_CLOCK) return;
        stopAlarm();
        resetState();
        update();
        if (vibrator != null && vibrator.hasVibrator()) {
            try {
                vibrator.vibrate(VibrationEffect.createOneShot(40L, VibrationEffect.DEFAULT_AMPLITUDE));
            } catch (Exception ignored) {
            }
        }
    }

    private void onCountdownFinished() {
        timerRunning = false;
        accumulatedMs = totalMs;
        alarming = true;
        playSound(RingtoneManager.TYPE_ALARM, true, 30000L,
                new long[]{0, 600, 400, 600, 400, 600, 400});
    }

    private void nextPhase() {
        if (phase == PHASE_WORK) {
            phase = round >= roundsBeforeLong ? PHASE_LONG : PHASE_SHORT;
        } else if (phase == PHASE_SHORT) {
            round++;
            phase = PHASE_WORK;
        } else {
            round = 1;
            phase = PHASE_WORK;
        }
        totalMs = phaseMs(phase);
        accumulatedMs = 0L;
        baseElapsed = SystemClock.elapsedRealtime();
        playSound(RingtoneManager.TYPE_NOTIFICATION, false, 3000L, new long[]{0, 250, 150, 250});
    }

    private static String fmt(long ms, boolean roundUp) {
        long s = roundUp ? (ms + 999L) / 1000L : ms / 1000L;
        long h = s / 3600L;
        long m = (s % 3600L) / 60L;
        long sec = s % 60L;
        if (h > 0) return String.format(Locale.US, "%d:%02d:%02d", h, m, sec);
        return String.format(Locale.US, "%02d:%02d", m, sec);
    }

    private void update() {
        if (bubble == null) return;
        long now = SystemClock.elapsedRealtime();
        String text;
        String lbl = null;
        float prog = -1f;
        int ringOverride = 0;

        if (mode == Prefs.MODE_CLOCK) {
            Date date = new Date();
            String pattern = clock24 ? (clockSec ? "HH:mm:ss" : "HH:mm") : (clockSec ? "h:mm:ss" : "h:mm");
            text = new SimpleDateFormat(pattern, Locale.US).format(date);
            if (clock24) {
                lbl = new SimpleDateFormat("EEE", Locale.getDefault()).format(date).toUpperCase(Locale.getDefault());
            } else {
                lbl = new SimpleDateFormat("a", Locale.US).format(date).toUpperCase(Locale.US);
            }
        } else {
            long el = accumulatedMs + (timerRunning ? now - baseElapsed : 0L);
            if (mode == Prefs.MODE_STOPWATCH) {
                text = fmt(el, false);
                prog = (el % 60000L) / 60000f;
                lbl = timerRunning ? null : "PAUSED";
            } else if (mode == Prefs.MODE_COUNTDOWN) {
                long rem = totalMs - el;
                if (timerRunning && rem <= 0L) {
                    onCountdownFinished();
                    rem = 0L;
                }
                if (rem < 0L) rem = 0L;
                text = fmt(rem, true);
                prog = totalMs > 0L ? rem / (float) totalMs : 0f;
                lbl = alarming ? "DONE" : (timerRunning ? null : "PAUSED");
            } else {
                long rem = totalMs - el;
                if (timerRunning && rem <= 0L) {
                    nextPhase();
                    el = accumulatedMs + (timerRunning ? now - baseElapsed : 0L);
                    rem = totalMs - el;
                }
                if (rem < 0L) rem = 0L;
                text = fmt(rem, true);
                prog = totalMs > 0L ? rem / (float) totalMs : 0f;
                if (!timerRunning) {
                    lbl = "PAUSED";
                } else if (phase == PHASE_WORK) {
                    lbl = "FOCUS " + round + "/" + roundsBeforeLong;
                } else if (phase == PHASE_SHORT) {
                    lbl = "BREAK";
                } else {
                    lbl = "LONG BREAK";
                }
                ringOverride = phase == PHASE_WORK ? 0 : BREAK_COLOR;
            }
        }

        boolean flash = alarming && ((now / 500L) % 2L == 0L);
        bubble.setState(text, lbl, prog, ringOverride, flash);
    }

    // ------------------------------------------------------------ sound and vibration

    private void playSound(int type, boolean loop, long timeoutMs, long[] pattern) {
        stopAlarmSound();
        if (Prefs.getInt(prefs, Prefs.SOUND) == 1) {
            try {
                Uri uri = RingtoneManager.getDefaultUri(type);
                if (uri == null) uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
                ringtone = RingtoneManager.getRingtone(this, uri);
                if (ringtone != null) {
                    ringtone.setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build());
                    if (Build.VERSION.SDK_INT >= 28) ringtone.setLooping(loop);
                    ringtone.play();
                }
            } catch (Exception ignored) {
            }
        }
        if (Prefs.getInt(prefs, Prefs.VIBRATE) == 1 && vibrator != null && vibrator.hasVibrator()) {
            try {
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, loop ? 0 : -1));
            } catch (Exception ignored) {
            }
        }
        handler.removeCallbacks(stopSoundRunnable);
        handler.postDelayed(stopSoundRunnable, timeoutMs);
    }

    private void stopAlarmSound() {
        handler.removeCallbacks(stopSoundRunnable);
        if (ringtone != null) {
            try {
                ringtone.stop();
            } catch (Exception ignored) {
            }
            ringtone = null;
        }
        if (vibrator != null) {
            try {
                vibrator.cancel();
            } catch (Exception ignored) {
            }
        }
    }

    private void stopAlarm() {
        stopAlarmSound();
        alarming = false;
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/MainActivity.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** Settings screen: pick a mode, style the bubble, start it. */
public class MainActivity extends Activity {
    private static final int C_BG = 0xFF0E1014;
    private static final int C_CARD = 0xFF171A21;
    private static final int C_LINE = 0xFF262A33;
    private static final int C_TEXT = 0xFFF2F4F8;
    private static final int C_SUB = 0xFF8B93A3;
    private static final int C_ACCENT = 0xFF7C9CFF;

    private static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT;
    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;

    private static final int N_NONE = 0;
    private static final int N_STYLE = 1;
    private static final int N_CONFIG = 2;

    private static final int[] PALETTE = {
            0xFF14161C, 0xFF000000, 0xFFFFFFFF, 0xFFF4F1EA, 0xFF1F2A44, 0xFF7C9CFF,
            0xFF5BD6A0, 0xFFFFB86B, 0xFFFF6B81, 0xFFB794F6, 0xFFFFE066, 0xFF4DD0E1
    };

    private static final String[] THEME_NAMES = {"Midnight", "Snow", "Mint", "Sunset", "Ocean", "Mono"};
    private static final int[][] THEMES = {
            {0xFF14161C, 0xFFFFFFFF, 0xFF7C9CFF},
            {0xFFF7F7F5, 0xFF14161C, 0xFF3B5BDB},
            {0xFF0F2A24, 0xFFE9FFF6, 0xFF5BD6A0},
            {0xFF2A1620, 0xFFFFF1E6, 0xFFFFB86B},
            {0xFF0C2233, 0xFFEAF6FF, 0xFF4DD0E1},
            {0xFF000000, 0xFFFFFFFF, 0xFFFFFFFF}
    };

    private interface IntCb {
        void on(int value);
    }

    private SharedPreferences p;
    private float density;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private LinearLayout content;
    private LinearLayout modeCard;
    private LinearLayout styleCard;
    private BubbleView preview;
    private TextView startBtn;

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            updateStartBtn();
            if (Prefs.getInt(p, Prefs.MODE) == Prefs.MODE_CLOCK) refreshPreview();
            handler.postDelayed(this, 1000L);
        }
    };

    // ------------------------------------------------------------ lifecycle

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        p = Prefs.get(this);
        density = getResources().getDisplayMetrics().density;
        getWindow().setStatusBarColor(C_BG);
        getWindow().setNavigationBarColor(C_BG);

        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(C_BG);
        sv.setFillViewport(true);
        FrameLayout frame = new FrameLayout(this);
        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(20), dp(28), dp(20), dp(40));
        int screenW = getResources().getDisplayMetrics().widthPixels;
        FrameLayout.LayoutParams flp = new FrameLayout.LayoutParams(
                Math.min(screenW, dp(640)), WRAP, Gravity.CENTER_HORIZONTAL);
        frame.addView(content, flp);
        sv.addView(frame, new ViewGroup.LayoutParams(MATCH, WRAP));
        setContentView(sv);

        build();

        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.removeCallbacks(poll);
        handler.post(poll);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(poll);
        super.onPause();
    }

    // ------------------------------------------------------------ small helpers

    private int dp(float v) {
        return Math.round(v * density);
    }

    private GradientDrawable rounded(int color, float radiusDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(dp(radiusDp));
        return g;
    }

    private TextView text(String s, float sp, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        return t;
    }

    private LinearLayout.LayoutParams lp(int w, int h, float l, float t, float r, float b) {
        LinearLayout.LayoutParams x = new LinearLayout.LayoutParams(w, h);
        x.setMargins(dp(l), dp(t), dp(r), dp(b));
        return x;
    }

    private LinearLayout vertical() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    private LinearLayout horizontal() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setGravity(Gravity.CENTER_VERTICAL);
        return l;
    }

    private LinearLayout newCard() {
        LinearLayout l = vertical();
        l.setBackground(rounded(C_CARD, 20));
        l.setPadding(dp(18), dp(14), dp(18), dp(14));
        return l;
    }

    private TextView caption(String s) {
        TextView t = text(s, 12, C_SUB);
        t.setLetterSpacing(0.12f);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        return t;
    }

    private TextView sub(String s) {
        TextView t = text(s, 13, C_SUB);
        t.setPadding(0, dp(2), 0, dp(6));
        return t;
    }

    // ------------------------------------------------------------ building the screen

    private void build() {
        content.removeAllViews();

        TextView title = text("Floaty", 30, C_TEXT);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        content.addView(title, lp(MATCH, WRAP, 0, 0, 0, 0));
        content.addView(text("A tiny floating timer. Free, no ads, no tracking.", 14, C_SUB),
                lp(MATCH, WRAP, 0, 2, 0, 0));

        // live preview
        FrameLayout pv = new FrameLayout(this);
        GradientDrawable pg = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0xFF4A5060, 0xFF22262F});
        pg.setCornerRadius(dp(24));
        pv.setBackground(pg);
        pv.setPadding(0, dp(24), 0, dp(24));
        pv.setMinimumHeight(dp(190));
        preview = new BubbleView(this);
        pv.addView(preview, new FrameLayout.LayoutParams(WRAP, WRAP, Gravity.CENTER));
        content.addView(pv, lp(MATCH, WRAP, 0, 18, 0, 0));

        // mode
        content.addView(caption("MODE"), lp(MATCH, WRAP, 4, 22, 0, 8));
        content.addView(segmented(new String[]{"Timer", "Stopwatch", "Pomodoro", "Clock"},
                Prefs.getInt(p, Prefs.MODE), new IntCb() {
                    @Override
                    public void on(int v) {
                        p.edit().putInt(Prefs.MODE, v).apply();
                        buildModeSettings();
                        changed(N_CONFIG);
                    }
                }), lp(MATCH, WRAP, 0, 0, 0, 0));

        modeCard = newCard();
        content.addView(modeCard, lp(MATCH, WRAP, 0, 12, 0, 0));
        buildModeSettings();

        // style
        content.addView(caption("STYLE"), lp(MATCH, WRAP, 4, 22, 0, 8));
        styleCard = newCard();
        content.addView(styleCard, lp(MATCH, WRAP, 0, 0, 0, 0));
        buildStyleCard();

        // alerts
        content.addView(caption("ALERTS"), lp(MATCH, WRAP, 4, 22, 0, 8));
        LinearLayout alerts = newCard();
        alerts.addView(toggle("Sound", Prefs.SOUND, N_NONE));
        alerts.addView(toggle("Vibration", Prefs.VIBRATE, N_NONE));
        content.addView(alerts, lp(MATCH, WRAP, 0, 0, 0, 0));

        // start / stop
        startBtn = text("", 17, 0xFF0E1014);
        startBtn.setGravity(Gravity.CENTER);
        startBtn.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        startBtn.setPadding(0, dp(17), 0, dp(17));
        startBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                onStartStop();
            }
        });
        content.addView(startBtn, lp(MATCH, WRAP, 0, 26, 0, 0));
        content.addView(sub("Tip: tap the bubble to pause or resume. Long-press to reset. "
                + "Drag it to the ✕ at the bottom to close it."), lp(MATCH, WRAP, 4, 10, 4, 0));

        refreshPreview();
        updateStartBtn();
    }

    private void buildModeSettings() {
        modeCard.removeAllViews();
        int m = Prefs.getInt(p, Prefs.MODE);
        if (m == Prefs.MODE_COUNTDOWN) {
            modeCard.addView(sub("Counts down, then rings."));
            LinearLayout chips = horizontal();
            int[] quick = {1, 5, 10, 15, 25, 45, 60};
            for (int i = 0; i < quick.length; i++) {
                final int v = quick[i];
                TextView c = chip(v + "m", new View.OnClickListener() {
                    @Override
                    public void onClick(View x) {
                        p.edit().putInt(Prefs.CD_MIN, v).putInt(Prefs.CD_SEC, 0).apply();
                        buildModeSettings();
                        changed(N_CONFIG);
                    }
                });
                chips.addView(c, lp(WRAP, WRAP, 0, 0, 6, 0));
            }
            HorizontalScrollView hs = new HorizontalScrollView(this);
            hs.setHorizontalScrollBarEnabled(false);
            hs.addView(chips);
            modeCard.addView(hs, lp(MATCH, WRAP, 0, 4, 0, 6));
            modeCard.addView(stepper("Minutes", Prefs.CD_MIN, 0, 600, 1, "min", N_CONFIG));
            modeCard.addView(stepper("Seconds", Prefs.CD_SEC, 0, 55, 5, "sec", N_CONFIG));
        } else if (m == Prefs.MODE_STOPWATCH) {
            modeCard.addView(sub("Counts up from zero."));
        } else if (m == Prefs.MODE_POMODORO) {
            modeCard.addView(sub("Focus and break rounds that switch on their own."));
            modeCard.addView(stepper("Focus", Prefs.POMO_WORK, 1, 120, 1, "min", N_CONFIG));
            modeCard.addView(stepper("Short break", Prefs.POMO_SHORT, 1, 60, 1, "min", N_CONFIG));
            modeCard.addView(stepper("Long break", Prefs.POMO_LONG, 1, 90, 1, "min", N_CONFIG));
            modeCard.addView(stepper("Rounds before long break", Prefs.POMO_ROUNDS, 1, 12, 1, "", N_CONFIG));
        } else {
            modeCard.addView(sub("Shows the current time."));
            modeCard.addView(toggle("24-hour clock", Prefs.CLOCK_24, N_STYLE));
            modeCard.addView(toggle("Show seconds", Prefs.CLOCK_SEC, N_STYLE));
        }
    }

    private void buildStyleCard() {
        styleCard.removeAllViews();

        styleCard.addView(sub("Themes"));
        LinearLayout themes = horizontal();
        for (int i = 0; i < THEMES.length; i++) {
            final int idx = i;
            LinearLayout item = vertical();
            item.setGravity(Gravity.CENTER_HORIZONTAL);
            TextView circle = text("Aa", 14, THEMES[i][1]);
            circle.setGravity(Gravity.CENTER);
            GradientDrawable gd = new GradientDrawable();
            gd.setShape(GradientDrawable.OVAL);
            gd.setColor(THEMES[i][0]);
            gd.setStroke(dp(2), THEMES[i][2]);
            circle.setBackground(gd);
            item.addView(circle, new LinearLayout.LayoutParams(dp(50), dp(50)));
            TextView name = text(THEME_NAMES[i], 11, C_SUB);
            name.setPadding(0, dp(4), 0, 0);
            item.addView(name);
            item.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    p.edit().putInt(Prefs.BG, THEMES[idx][0])
                            .putInt(Prefs.FG, THEMES[idx][1])
                            .putInt(Prefs.ACCENT, THEMES[idx][2]).apply();
                    buildStyleCard();
                    changed(N_STYLE);
                }
            });
            themes.addView(item, lp(WRAP, WRAP, 0, 0, 14, 0));
        }
        HorizontalScrollView ths = new HorizontalScrollView(this);
        ths.setHorizontalScrollBarEnabled(false);
        ths.addView(themes);
        styleCard.addView(ths);

        styleCard.addView(sub("Shape"), lp(MATCH, WRAP, 0, 12, 0, 0));
        styleCard.addView(segmented(new String[]{"Circle", "Squircle", "Pill"},
                Prefs.getInt(p, Prefs.SHAPE), new IntCb() {
                    @Override
                    public void on(int v) {
                        p.edit().putInt(Prefs.SHAPE, v).apply();
                        changed(N_STYLE);
                    }
                }));

        styleCard.addView(sub("Font"), lp(MATCH, WRAP, 0, 12, 0, 0));
        styleCard.addView(segmented(new String[]{"Light", "Regular", "Bold", "Mono"},
                Prefs.getInt(p, Prefs.FONT), new IntCb() {
                    @Override
                    public void on(int v) {
                        p.edit().putInt(Prefs.FONT, v).apply();
                        changed(N_STYLE);
                    }
                }));

        styleCard.addView(toggle("Progress ring / bar", Prefs.RING, N_STYLE), lp(MATCH, WRAP, 0, 8, 0, 0));
        styleCard.addView(slider("Size", Prefs.SIZE, 60, 240, "dp", N_STYLE));
        styleCard.addView(slider("Transparency", Prefs.OPACITY, 30, 100, "%", N_STYLE));

        styleCard.addView(sub("Background colour"), lp(MATCH, WRAP, 0, 12, 0, 0));
        styleCard.addView(swatches(Prefs.BG));
        styleCard.addView(sub("Text colour"), lp(MATCH, WRAP, 0, 8, 0, 0));
        styleCard.addView(swatches(Prefs.FG));
        styleCard.addView(sub("Accent colour (ring and label)"), lp(MATCH, WRAP, 0, 8, 0, 0));
        styleCard.addView(swatches(Prefs.ACCENT));
    }

    // ------------------------------------------------------------ reusable controls

    private TextView chip(String label, View.OnClickListener l) {
        TextView t = text(label, 14, C_TEXT);
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(14), dp(8), dp(14), dp(8));
        t.setBackground(rounded(C_LINE, 14));
        t.setOnClickListener(l);
        return t;
    }

    private View segmented(String[] labels, int selected, final IntCb cb) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setBackground(rounded(C_BG, 14));
        row.setPadding(dp(4), dp(4), dp(4), dp(4));
        final TextView[] items = new TextView[labels.length];
        for (int i = 0; i < labels.length; i++) {
            final int idx = i;
            TextView t = text(labels[i], 14, C_SUB);
            t.setGravity(Gravity.CENTER);
            t.setPadding(0, dp(10), 0, dp(10));
            items[i] = t;
            row.addView(t, new LinearLayout.LayoutParams(0, WRAP, 1f));
            t.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    paintSegments(items, idx);
                    cb.on(idx);
                }
            });
        }
        paintSegments(items, selected);
        return row;
    }

    private void paintSegments(TextView[] items, int selected) {
        for (int j = 0; j < items.length; j++) {
            boolean on = j == selected;
            items[j].setTextColor(on ? 0xFF0E1014 : C_SUB);
            items[j].setBackground(on ? rounded(C_ACCENT, 10) : null);
        }
    }

    private View toggle(String label, final String key, final int notify) {
        LinearLayout row = horizontal();
        row.setPadding(0, dp(6), 0, dp(6));
        row.addView(text(label, 15, C_TEXT), new LinearLayout.LayoutParams(0, WRAP, 1f));
        Switch sw = new Switch(this);
        sw.setChecked(Prefs.getInt(p, key) == 1);
        sw.setOnCheckedChangeListener(new android.widget.CompoundButton.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(android.widget.CompoundButton b, boolean checked) {
                p.edit().putInt(key, checked ? 1 : 0).apply();
                changed(notify);
            }
        });
        row.addView(sw);
        return row;
    }

    private View stepper(String label, final String key, final int min, final int max,
                         final int step, final String unit, final int notify) {
        LinearLayout row = horizontal();
        row.setPadding(0, dp(6), 0, dp(6));
        row.addView(text(label, 15, C_TEXT), new LinearLayout.LayoutParams(0, WRAP, 1f));
        final TextView val = text(Prefs.getInt(p, key) + " " + unit, 15, C_TEXT);
        val.setGravity(Gravity.CENTER);
        TextView minus = chip("–", null);
        TextView plus = chip("+", null);
        minus.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                int c = Math.max(min, Prefs.getInt(p, key) - step);
                p.edit().putInt(key, c).apply();
                val.setText(c + " " + unit);
                changed(notify);
            }
        });
        plus.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                int c = Math.min(max, Prefs.getInt(p, key) + step);
                p.edit().putInt(key, c).apply();
                val.setText(c + " " + unit);
                changed(notify);
            }
        });
        row.addView(minus);
        row.addView(val, new LinearLayout.LayoutParams(dp(76), WRAP));
        row.addView(plus);
        return row;
    }

    private View slider(String label, final String key, final int min, int max,
                        final String unit, final int notify) {
        LinearLayout box = vertical();
        box.setPadding(0, dp(8), 0, 0);
        LinearLayout head = horizontal();
        head.addView(text(label, 15, C_TEXT), new LinearLayout.LayoutParams(0, WRAP, 1f));
        final TextView val = text(Prefs.getInt(p, key) + " " + unit, 14, C_SUB);
        head.addView(val);
        box.addView(head);
        SeekBar sb = new SeekBar(this);
        sb.setMax(max - min);
        sb.setProgress(Prefs.getInt(p, key) - min);
        sb.setProgressTintList(ColorStateList.valueOf(C_ACCENT));
        sb.setThumbTintList(ColorStateList.valueOf(C_ACCENT));
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar s, int progress, boolean fromUser) {
                int v = progress + min;
                val.setText(v + " " + unit);
                if (fromUser) {
                    p.edit().putInt(key, v).apply();
                    changed(notify);
                }
            }

            @Override
            public void onStartTrackingTouch(SeekBar s) {
            }

            @Override
            public void onStopTrackingTouch(SeekBar s) {
            }
        });
        box.addView(sb);
        return box;
    }

    private View swatches(final String key) {
        int current = Prefs.getInt(p, key);
        LinearLayout row = horizontal();
        boolean matched = false;
        for (int i = 0; i < PALETTE.length; i++) {
            final int color = PALETTE[i];
            boolean sel = color == current;
            if (sel) matched = true;
            row.addView(swatchDot(color, sel, "", new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    p.edit().putInt(key, color).apply();
                    buildStyleCard();
                    changed(N_STYLE);
                }
            }), lp(WRAP, WRAP, 0, 4, 10, 4));
        }
        row.addView(swatchDot(matched ? C_LINE : current, !matched, "#", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                customColor(key);
            }
        }), lp(WRAP, WRAP, 0, 4, 10, 4));
        HorizontalScrollView hs = new HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        hs.addView(row);
        return hs;
    }

    private View swatchDot(int color, boolean selected, String label, View.OnClickListener l) {
        TextView t = text(label, 14, 0xFFFFFFFF);
        t.setGravity(Gravity.CENTER);
        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.OVAL);
        gd.setColor(color);
        gd.setStroke(dp(selected ? 3 : 1), selected ? C_ACCENT : 0x55FFFFFF);
        t.setBackground(gd);
        t.setLayoutParams(new LinearLayout.LayoutParams(dp(36), dp(36)));
        t.setOnClickListener(l);
        return t;
    }

    private void customColor(final String key) {
        final EditText et = new EditText(this);
        et.setSingleLine(true);
        et.setHint("#RRGGBB");
        et.setText(String.format(Locale.US, "#%06X", 0xFFFFFF & Prefs.getInt(p, key)));
        new AlertDialog.Builder(this)
                .setTitle("Custom colour")
                .setView(et)
                .setPositiveButton("OK", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface dlg, int which) {
                        try {
                            String s = et.getText().toString().trim();
                            if (!s.startsWith("#")) s = "#" + s;
                            int c = Color.parseColor(s) | 0xFF000000;
                            p.edit().putInt(key, c).apply();
                            buildStyleCard();
                            changed(N_STYLE);
                        } catch (IllegalArgumentException ex) {
                            Toast.makeText(MainActivity.this, "That is not a valid colour code",
                                    Toast.LENGTH_SHORT).show();
                        }
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    // ------------------------------------------------------------ preview and service

    private void changed(int notify) {
        refreshPreview();
        if (notify == N_STYLE) {
            sendToService(FloatingService.ACTION_REFRESH);
        } else if (notify == N_CONFIG) {
            sendToService(FloatingService.ACTION_CONFIG);
        }
    }

    private void sendToService(String action) {
        if (!FloatingService.active) return;
        Intent i = new Intent(this, FloatingService.class);
        i.setAction(action);
        startService(i);
    }

    private void refreshPreview() {
        if (preview == null) return;
        preview.applyPrefs(p);
        int m = Prefs.getInt(p, Prefs.MODE);
        String t;
        String l = null;
        float prog = 0.7f;
        if (m == Prefs.MODE_COUNTDOWN) {
            int min = Prefs.getInt(p, Prefs.CD_MIN);
            int sec = Prefs.getInt(p, Prefs.CD_SEC);
            t = min >= 60
                    ? String.format(Locale.US, "%d:%02d:%02d", min / 60, min % 60, sec)
                    : String.format(Locale.US, "%02d:%02d", min, sec);
        } else if (m == Prefs.MODE_STOPWATCH) {
            t = "01:23";
            prog = 0.4f;
        } else if (m == Prefs.MODE_POMODORO) {
            t = String.format(Locale.US, "%02d:00", Prefs.getInt(p, Prefs.POMO_WORK));
            l = "FOCUS 1/" + Prefs.getInt(p, Prefs.POMO_ROUNDS);
        } else {
            boolean h24 = Prefs.getInt(p, Prefs.CLOCK_24) == 1;
            boolean secs = Prefs.getInt(p, Prefs.CLOCK_SEC) == 1;
            String pattern = h24 ? (secs ? "HH:mm:ss" : "HH:mm") : (secs ? "h:mm:ss" : "h:mm");
            Date now = new Date();
            t = new SimpleDateFormat(pattern, Locale.US).format(now);
            l = h24 ? new SimpleDateFormat("EEE", Locale.getDefault()).format(now).toUpperCase(Locale.getDefault())
                    : new SimpleDateFormat("a", Locale.US).format(now).toUpperCase(Locale.US);
            prog = -1f;
        }
        preview.setState(t, l, prog, 0, false);
    }

    private void updateStartBtn() {
        if (startBtn == null) return;
        if (FloatingService.active) {
            startBtn.setText("Stop floating timer");
            startBtn.setTextColor(C_TEXT);
            startBtn.setBackground(rounded(C_LINE, 18));
        } else {
            startBtn.setText("Start floating timer");
            startBtn.setTextColor(0xFF0E1014);
            startBtn.setBackground(rounded(C_ACCENT, 18));
        }
    }

    private void onStartStop() {
        if (FloatingService.active) {
            sendToService(FloatingService.ACTION_STOP);
            handler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    updateStartBtn();
                }
            }, 300L);
            return;
        }
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "Turn on \"Display over other apps\" for Floaty, then come back.",
                    Toast.LENGTH_LONG).show();
            startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName())));
            return;
        }
        startForegroundService(new Intent(this, FloatingService.class));
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                updateStartBtn();
            }
        }, 300L);
        moveTaskToBack(true);
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/Prefs.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.Context;
import android.content.SharedPreferences;

/** All saved settings live here, with their default values. */
final class Prefs {
    private Prefs() { }

    static final int MODE_COUNTDOWN = 0;
    static final int MODE_STOPWATCH = 1;
    static final int MODE_POMODORO = 2;
    static final int MODE_CLOCK = 3;

    static final int SHAPE_CIRCLE = 0;
    static final int SHAPE_SQUIRCLE = 1;
    static final int SHAPE_PILL = 2;

    static final int FONT_LIGHT = 0;
    static final int FONT_REGULAR = 1;
    static final int FONT_BOLD = 2;
    static final int FONT_MONO = 3;

    static final String MODE = "mode";
    static final String CD_MIN = "cd_min";
    static final String CD_SEC = "cd_sec";
    static final String POMO_WORK = "pomo_work";
    static final String POMO_SHORT = "pomo_short";
    static final String POMO_LONG = "pomo_long";
    static final String POMO_ROUNDS = "pomo_rounds";
    static final String CLOCK_24 = "clock_24";
    static final String CLOCK_SEC = "clock_sec";
    static final String SHAPE = "shape";
    static final String FONT = "font";
    static final String RING = "ring";
    static final String SIZE = "size_dp";
    static final String OPACITY = "opacity";
    static final String BG = "bg";
    static final String FG = "fg";
    static final String ACCENT = "accent";
    static final String SOUND = "sound";
    static final String VIBRATE = "vibrate";
    static final String POS_X = "pos_x";
    static final String POS_Y = "pos_y";

    static SharedPreferences get(Context c) {
        return c.getApplicationContext().getSharedPreferences("floaty", Context.MODE_PRIVATE);
    }

    static int getInt(SharedPreferences p, String key) {
        return p.getInt(key, defaultFor(key));
    }

    static int defaultFor(String key) {
        switch (key) {
            case MODE: return MODE_COUNTDOWN;
            case CD_MIN: return 10;
            case CD_SEC: return 0;
            case POMO_WORK: return 25;
            case POMO_SHORT: return 5;
            case POMO_LONG: return 15;
            case POMO_ROUNDS: return 4;
            case CLOCK_24: return 1;
            case CLOCK_SEC: return 0;
            case SHAPE: return SHAPE_CIRCLE;
            case FONT: return FONT_REGULAR;
            case RING: return 1;
            case SIZE: return 110;
            case OPACITY: return 95;
            case BG: return 0xFF14161C;
            case FG: return 0xFFFFFFFF;
            case ACCENT: return 0xFF7C9CFF;
            case SOUND: return 1;
            case VIBRATE: return 1;
            case POS_X: return -1;
            case POS_Y: return -1;
            default: return 0;
        }
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_fg.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#00000000"
        android:pathData="M32,54 A22,22 0 1,0 76,54 A22,22 0 1,0 32,54"
        android:strokeColor="#7C9CFF"
        android:strokeLineCap="round"
        android:strokeWidth="5" />
    <path
        android:fillColor="#00000000"
        android:pathData="M54,54 L54,40 M54,54 L64,60"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeWidth="4" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/mipmap-anydpi-v26'
cat > 'app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_bg" />
    <foreground android:drawable="@drawable/ic_fg" />
</adaptive-icon>
FLOATY_EOF
mkdir -p 'app/src/main/res/values'
cat > 'app/src/main/res/values/strings.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Floaty</string>
    <color name="ic_bg">#0E1014</color>
</resources>
FLOATY_EOF
