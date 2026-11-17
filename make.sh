#!/bin/bash
set -e
mkdir -p 'app'
cat > 'app/build.gradle' <<'FLOATY_EOF'
plugins {
    id 'com.android.application'
}

android {
    namespace 'com.floaty.timer'
    compileSdk 34

    defaultConfig {
        applicationId 'com.watchu.timer'
        minSdk 26
        targetSdk 34
        versionCode Integer.parseInt(System.getenv('BUILD_NUMBER') ?: '1')
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

        <activity
            android:name=".SettingsActivity"
            android:exported="false" />

        <activity
            android:name=".GuideActivity"
            android:exported="false" />

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
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PathMeasure;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.os.SystemClock;
import android.view.View;

/** The floating bubble. Draws the shape, the time, a small label and a progress ring/bar. */
class BubbleView extends View {
    int shape = Prefs.SHAPE_CIRCLE;
    int font = Prefs.FONT_REGULAR;
    int ringW = 3;
    int bg = 0xFF14161C;
    int bg2 = 0xFF3B2A6B;
    int bgMode = Prefs.BGMODE_SOLID;
    int fg = 0xFFFFFFFF;
    int accent = 0xFF7C9CFF;
    int opacityPct = 95;
    int sizeDp = 110;

    /** Analog watch mode: 0 = off (digital), otherwise a Prefs.FACE_* value. */
    int analogFace = 0;
    float angHour = 0f;
    float angMin = 0f;
    float angSec = 0f;
    boolean showSecHand = false;

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
    private final RectF corner = new RectF();
    private final Path ringPath = new Path();
    private final Path seg = new Path();

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
        ringW = Prefs.getInt(p, Prefs.RING);
        sizeDp = Prefs.getInt(p, Prefs.SIZE);
        opacityPct = Prefs.getInt(p, Prefs.OPACITY);
        bg = Prefs.getInt(p, Prefs.BG);
        bg2 = Prefs.getInt(p, Prefs.BG2);
        bgMode = Prefs.getInt(p, Prefs.BGMODE);
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
        analogFace = 0;
        invalidate();
    }

    /** Draw an analog watch face instead of digits. Angles are in degrees clockwise from 12. */
    void setAnalog(int face, float hourDeg, float minDeg, float secDeg, boolean secHand, String l) {
        analogFace = face;
        angHour = hourDeg;
        angMin = minDeg;
        angSec = secDeg;
        showSecHand = secHand;
        label = l;
        progress = -1f;
        ringColor = 0;
        highlight = false;
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

    private static float luminance(int color) {
        return (0.299f * Color.red(color) + 0.587f * Color.green(color) + 0.114f * Color.blue(color)) / 255f;
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
        boolean gradient = !highlight && bgMode != Prefs.BGMODE_SOLID;
        if (gradient) {
            int g1 = bg;
            int g2 = bg2;
            if (bgMode == Prefs.BGMODE_ANIM) {
                float hue = (SystemClock.uptimeMillis() % 24000L) / 24000f * 360f;
                boolean lightText = luminance(fg) > 0.5f;
                float sat = lightText ? 0.65f : 0.35f;
                float val = lightText ? 0.45f : 0.97f;
                g1 = Color.HSVToColor(new float[]{hue, sat, val});
                g2 = Color.HSVToColor(new float[]{(hue + 70f) % 360f, sat, val});
            }
            fill.setShader(new LinearGradient(0f, 0f, w, h,
                    withAlpha(g1, a), withAlpha(g2, a), Shader.TileMode.CLAMP));
        }
        drawShape(c, r, fill, w, h);
        fill.setShader(null);
        outline.setColor(withAlpha(ink, Math.min(a, 38)));
        drawShape(c, r, outline, w, h);

        if (analogFace != 0) {
            drawAnalog(c, w, h, ink, accentC);
            return;
        }

        boolean circle = shape == Prefs.SHAPE_CIRCLE;
        boolean pill = shape == Prefs.SHAPE_PILL;
        boolean showProgress = ringW > 0 && progress >= 0f;
        boolean ringOn = showProgress;
        boolean hasLabel = label != null && !pill;

        float base = pill ? h * 0.42f : h * 0.27f;
        float avail = circle ? w * (ringOn ? 0.58f : 0.74f) : w * (ringOn ? 0.66f : 0.78f);
        mainText.setColor(ink);
        mainText.setTextSize(base);
        float mw = mainText.measureText(text);
        if (mw > avail) mainText.setTextSize(base * avail / mw);
        float ms = mainText.getTextSize();

        if (ringOn) {
            float frac = ringW == 1 ? 0.03f : (ringW == 2 ? 0.05f : 0.075f);
            float sw = Math.min(w, h) * frac;
            float pad = sw * 1.5f;
            arc.setStrokeWidth(sw);
            r2.set(pad, pad, w - pad, h - pad);
            if (circle) {
                arc.setColor(withAlpha(ink, 40));
                c.drawOval(r2, arc);
                arc.setColor(accentC);
                c.drawArc(r2, -90f, 360f * clamp01(progress), false, arc);
            } else {
                float outer = pill ? h / 2f : Math.min(w, h) * 0.30f;
                float rad = Math.max(0f, outer - pad);
                buildRing(r2, rad);
                arc.setColor(withAlpha(ink, 40));
                c.drawPath(ringPath, arc);
                float p01 = clamp01(progress);
                if (p01 > 0.002f) {
                    PathMeasure pm = new PathMeasure(ringPath, false);
                    seg.rewind();
                    pm.getSegment(0f, pm.getLength() * p01, seg, true);
                    arc.setColor(accentC);
                    c.drawPath(seg, arc);
                }
            }
        }

        float cyMain = hasLabel ? h * 0.45f : h * 0.5f;
        float baseline = cyMain + ms * 0.36f;
        c.drawText(text, w / 2f, baseline, mainText);

        if (hasLabel) {
            float ls = ms * 0.36f;
            labelText.setTextSize(ls);
            float lw = labelText.measureText(label);
            float lavail = w * (circle ? 0.62f : 0.80f);
            if (lw > lavail) {
                ls = ls * lavail / lw;
                labelText.setTextSize(ls);
            }
            labelText.setColor(accentC);
            c.drawText(label, w / 2f, baseline + ls * 1.45f, labelText);
        }
    }

    /** A rounded rectangle path that starts at the top middle and runs clockwise. */
    private void buildRing(RectF b, float rad) {
        float d = rad * 2f;
        float cx = (b.left + b.right) / 2f;
        ringPath.rewind();
        ringPath.moveTo(cx, b.top);
        ringPath.lineTo(b.right - rad, b.top);
        corner.set(b.right - d, b.top, b.right, b.top + d);
        ringPath.arcTo(corner, -90f, 90f);
        ringPath.lineTo(b.right, b.bottom - rad);
        corner.set(b.right - d, b.bottom - d, b.right, b.bottom);
        ringPath.arcTo(corner, 0f, 90f);
        ringPath.lineTo(b.left + rad, b.bottom);
        corner.set(b.left, b.bottom - d, b.left + d, b.bottom);
        ringPath.arcTo(corner, 90f, 90f);
        ringPath.lineTo(b.left, b.top + rad);
        corner.set(b.left, b.top, b.left + d, b.top + d);
        ringPath.arcTo(corner, 180f, 90f);
        ringPath.lineTo(cx, b.top);
    }

    private void hand(Canvas c, float cx, float cy, float deg, float len, float tail,
                      float width, int color) {
        arc.setStyle(Paint.Style.STROKE);
        arc.setStrokeCap(Paint.Cap.ROUND);
        arc.setStrokeWidth(width);
        arc.setColor(color);
        double rad = Math.toRadians(deg);
        float dx = (float) Math.sin(rad);
        float dy = (float) -Math.cos(rad);
        c.drawLine(cx - dx * tail, cy - dy * tail, cx + dx * len, cy + dy * len, arc);
    }

    private void drawAnalog(Canvas c, float w, float h, int ink, int accentC) {
        float cx = w / 2f;
        float cy = h / 2f;
        float rad = Math.min(w, h) / 2f;
        float dial = rad * 0.86f;
        if (analogFace == Prefs.FACE_NUMBERS) {
            mainText.setColor(ink);
            mainText.setTextSize(dial * 0.30f);
            float off = mainText.getTextSize() * 0.36f;
            float nr = dial * 0.74f;
            c.drawText("12", cx, cy - nr + off, mainText);
            c.drawText("3", cx + nr, cy + off, mainText);
            c.drawText("6", cx, cy + nr + off, mainText);
            c.drawText("9", cx - nr, cy + off, mainText);
        } else {
            for (int i = 0; i < 12; i++) {
                boolean major = i % 3 == 0;
                float len = dial * (major ? 0.16f : 0.09f);
                double a = Math.toRadians(i * 30.0);
                float dx = (float) Math.sin(a);
                float dy = (float) -Math.cos(a);
                arc.setStyle(Paint.Style.STROKE);
                arc.setStrokeCap(Paint.Cap.ROUND);
                arc.setStrokeWidth(Math.max(density * 1.2f, dial * (major ? 0.05f : 0.03f)));
                arc.setColor(withAlpha(ink, major ? 255 : 150));
                c.drawLine(cx + dx * dial, cy + dy * dial, cx + dx * (dial - len), cy + dy * (dial - len), arc);
            }
        }
        hand(c, cx, cy, angHour, dial * 0.50f, dial * 0.06f, Math.max(density * 2f, dial * 0.08f), ink);
        hand(c, cx, cy, angMin, dial * 0.74f, dial * 0.06f, Math.max(density * 1.6f, dial * 0.055f), ink);
        if (showSecHand) {
            hand(c, cx, cy, angSec, dial * 0.80f, dial * 0.14f, Math.max(density, dial * 0.025f), accentC);
        }
        fill.setColor(accentC);
        c.drawCircle(cx, cy, Math.max(density * 2.5f, dial * 0.06f), fill);
        arc.setStrokeCap(Paint.Cap.ROUND);
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/ColorSlider.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Shader;
import android.view.MotionEvent;
import android.view.View;

/** A horizontal slider whose track is a colour gradient. Value goes from 0 to 1. */
class ColorSlider extends View {
    interface Listener {
        void onChange(float value);
    }

    private final float density;
    private final Paint track = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint thumbFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint thumbEdge = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();
    private int[] colors = {0xFF000000, 0xFFFFFFFF};
    private float value = 0f;
    private Listener listener;

    ColorSlider(Context c) {
        super(c);
        density = c.getResources().getDisplayMetrics().density;
        thumbFill.setColor(0xFFFFFFFF);
        thumbEdge.setStyle(Paint.Style.STROKE);
        thumbEdge.setStrokeWidth(2f * density);
        thumbEdge.setColor(0x66000000);
    }

    void setColors(int[] c) {
        colors = c;
        invalidate();
    }

    void setValue(float v) {
        value = v < 0f ? 0f : (v > 1f ? 1f : v);
        invalidate();
    }

    float getValue() {
        return value;
    }

    void setListener(Listener l) {
        listener = l;
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        int w = View.resolveSize(Math.round(200f * density), widthSpec);
        setMeasuredDimension(w, Math.round(44f * density));
    }

    @Override
    protected void onDraw(Canvas c) {
        float w = getWidth();
        float h = getHeight();
        float pad = h / 2f;
        float th = h * 0.42f;
        rect.set(pad, h / 2f - th / 2f, w - pad, h / 2f + th / 2f);
        track.setShader(new LinearGradient(rect.left, 0f, rect.right, 0f, colors, null, Shader.TileMode.CLAMP));
        c.drawRoundRect(rect, th / 2f, th / 2f, track);
        float x = rect.left + value * rect.width();
        c.drawCircle(x, h / 2f, h * 0.40f, thumbFill);
        c.drawCircle(x, h / 2f, h * 0.40f, thumbEdge);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int a = e.getActionMasked();
        if (a == MotionEvent.ACTION_DOWN || a == MotionEvent.ACTION_MOVE) {
            if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(true);
            float pad = getHeight() / 2f;
            float span = Math.max(1f, getWidth() - 2f * pad);
            setValue((e.getX() - pad) / span);
            if (listener != null) listener.onChange(value);
            return true;
        }
        return a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL;
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
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.animation.ValueAnimator;
import android.content.pm.ServiceInfo;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.Icon;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.Ringtone;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
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
import java.util.Calendar;
import java.util.Date;
import java.util.Locale;

/** Foreground service that owns the floating bubble and all timer logic. */
public class FloatingService extends Service {
    static final String ACTION_STOP = "com.watchu.timer.STOP";
    static final String ACTION_REFRESH = "com.watchu.timer.REFRESH";
    static final String ACTION_CONFIG = "com.watchu.timer.CONFIG";

    /** True while the service (and its bubble) exists. */
    static volatile boolean active = false;

    private static final String CHANNEL = "watchu_timer";
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
    private int cycle = 1;
    private long promptUntil;
    private boolean waitingStart;
    private boolean dragCancelled;
    private boolean screenPaused;
    private boolean motionPaused;
    private long lastMotionAt;
    private boolean sensing;
    private SensorManager sensorManager;

    private final BroadcastReceiver screenRx = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String a = intent.getAction();
            if (Intent.ACTION_SCREEN_OFF.equals(a)) {
                if (Prefs.getInt(prefs, Prefs.SCREEN_PAUSE) == 1 && timerRunning
                        && mode != Prefs.MODE_CLOCK && !alarming) {
                    pauseInternal();
                    screenPaused = true;
                    update();
                }
            } else if (Intent.ACTION_SCREEN_ON.equals(a)) {
                if (screenPaused) {
                    screenPaused = false;
                    if (!timerRunning && !motionPaused) resumeInternal();
                }
            }
        }
    };

    private final SensorEventListener motionListener = new SensorEventListener() {
        @Override
        public void onSensorChanged(SensorEvent e) {
            float x = e.values[0];
            float y = e.values[1];
            float z = e.values[2];
            double mag = Math.sqrt(x * x + y * y + z * z);
            if (Math.abs(mag - SensorManager.GRAVITY_EARTH) > 1.8) {
                lastMotionAt = SystemClock.elapsedRealtime();
            }
        }

        @Override
        public void onAccuracyChanged(Sensor sensor, int accuracy) {
        }
    };

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

    private final Runnable fadeRun = new Runnable() {
        @Override
        public void run() {
            if (bubble != null && !alarming && Prefs.getInt(prefs, Prefs.FADE) == 1) {
                bubble.animate().alpha(0.4f).setDuration(400L).start();
            }
        }
    };

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            update();
            checkMotion();
            boolean animated = bubble != null && bubble.bgMode == Prefs.BGMODE_ANIM;
            long delay = (timerRunning || mode == Prefs.MODE_CLOCK || alarming || animated) ? 200L : 500L;
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
        sensorManager = (SensorManager) getSystemService(SENSOR_SERVICE);
        IntentFilter screenFilter = new IntentFilter(Intent.ACTION_SCREEN_OFF);
        screenFilter.addAction(Intent.ACTION_SCREEN_ON);
        registerReceiver(screenRx, screenFilter);
        startAsForeground();
        createBubble();
        loadConfig();
        syncMotion();
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
            syncMotion();
        } else if (ACTION_CONFIG.equals(a)) {
            applyStyle();
            loadConfig();
            syncMotion();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(tick);
        handler.removeCallbacks(longPress);
        handler.removeCallbacks(fadeRun);
        handler.removeCallbacks(stopSoundRunnable);
        stopAlarmSound();
        stopMotion();
        try {
            unregisterReceiver(screenRx);
        } catch (Exception ignored) {
        }
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
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Watchu floating timer",
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
                .setContentTitle("Watchu is running")
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
                    dragCancelled = false;
                    wake();
                    handler.postDelayed(longPress, 600L);
                    return true;
                }
                if (action == MotionEvent.ACTION_MOVE) {
                    float dx = e.getRawX() - downX;
                    float dy = e.getRawY() - downY;
                    if (!moved && !dragCancelled && Math.hypot(dx, dy) > touchSlop) {
                        handler.removeCallbacks(longPress);
                        if (Prefs.getInt(prefs, Prefs.LOCK) == 1) {
                            dragCancelled = true;
                        } else {
                            moved = true;
                            showTrash();
                        }
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
                            finishDrag();
                        }
                    } else if (!longPressed && !dragCancelled && action == MotionEvent.ACTION_UP) {
                        onTap();
                    }
                    return true;
                }
                return false;
            }
        });

        wm.addView(bubble, bubbleLp);
        wake();
    }

    private void wake() {
        if (bubble == null) return;
        bubble.animate().cancel();
        bubble.setAlpha(1f);
        handler.removeCallbacks(fadeRun);
        if (Prefs.getInt(prefs, Prefs.FADE) == 1) handler.postDelayed(fadeRun, 5000L);
    }

    private void finishDrag() {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        final int bw = bubble.getWidth() > 0 ? bubble.getWidth() : bubble.widthPx();
        if (Prefs.getInt(prefs, Prefs.SNAP) == 1) {
            final int from = bubbleLp.x;
            final int to = (bubbleLp.x + bw / 2 < dm.widthPixels / 2) ? 0 : Math.max(0, dm.widthPixels - bw);
            ValueAnimator va = ValueAnimator.ofInt(from, to);
            va.setDuration(180L);
            va.addUpdateListener(new ValueAnimator.AnimatorUpdateListener() {
                @Override
                public void onAnimationUpdate(ValueAnimator a) {
                    if (bubble == null) return;
                    bubbleLp.x = (Integer) a.getAnimatedValue();
                    try {
                        wm.updateViewLayout(bubble, bubbleLp);
                    } catch (Exception ignored) {
                    }
                }
            });
            va.start();
            bubbleLp.x = to;
        }
        prefs.edit().putInt(Prefs.POS_X, bubbleLp.x).putInt(Prefs.POS_Y, bubbleLp.y).apply();
    }

    private void applyStyle() {
        if (bubble == null) return;
        wake();
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
        screenPaused = false;
        motionPaused = false;
        accumulatedMs = 0L;
        timerRunning = false;
        alarming = false;
        phase = PHASE_WORK;
        round = 1;
        cycle = 1;
        promptUntil = 0L;
        waitingStart = false;
        if (mode == Prefs.MODE_COUNTDOWN) {
            long ms = (Prefs.getInt(prefs, Prefs.CD_MIN) * 60L + Prefs.getInt(prefs, Prefs.CD_SEC)) * 1000L;
            totalMs = Math.max(1000L, ms);
        } else if (mode == Prefs.MODE_POMODORO) {
            totalMs = phaseMs(PHASE_WORK);
        } else {
            totalMs = 0L;
        }
    }

    private void pauseInternal() {
        if (!timerRunning) return;
        accumulatedMs += SystemClock.elapsedRealtime() - baseElapsed;
        timerRunning = false;
    }

    private void resumeInternal() {
        baseElapsed = SystemClock.elapsedRealtime();
        timerRunning = true;
        update();
    }

    private void syncMotion() {
        boolean want = Prefs.getInt(prefs, Prefs.MOTION_PAUSE) == 1;
        if (want && !sensing && sensorManager != null) {
            Sensor acc = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
            if (acc != null) {
                sensing = sensorManager.registerListener(motionListener, acc, SensorManager.SENSOR_DELAY_NORMAL);
            }
        } else if (!want && sensing) {
            stopMotion();
            motionPaused = false;
        }
    }

    private void stopMotion() {
        if (sensing && sensorManager != null) {
            try {
                sensorManager.unregisterListener(motionListener);
            } catch (Exception ignored) {
            }
        }
        sensing = false;
    }

    /** Pauses while the phone is being moved, resumes after it has been still for 5 seconds. */
    private void checkMotion() {
        if (!sensing || mode == Prefs.MODE_CLOCK || alarming) return;
        long now = SystemClock.elapsedRealtime();
        if (timerRunning && now - lastMotionAt < 600L) {
            pauseInternal();
            motionPaused = true;
            update();
        } else if (motionPaused && !timerRunning && !screenPaused && now - lastMotionAt > 5000L) {
            motionPaused = false;
            resumeInternal();
        }
    }

    private String pausedLabel() {
        return motionPaused ? "MOVING" : "PAUSED";
    }

    private void toggleRun() {
        screenPaused = false;
        motionPaused = false;
        long now = SystemClock.elapsedRealtime();
        if (timerRunning) {
            accumulatedMs += now - baseElapsed;
            timerRunning = false;
        } else {
            baseElapsed = now;
            timerRunning = true;
            waitingStart = false;
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
        if (mode == Prefs.MODE_POMODORO && phase != PHASE_WORK && timerRunning
                && SystemClock.elapsedRealtime() < promptUntil) {
            nextPhase(true);
            timerRunning = true;
            waitingStart = false;
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
        wake();
        playSound(RingtoneManager.TYPE_ALARM, true, 30000L,
                new long[]{0, 600, 400, 600, 400, 600, 400});
    }

    private void nextPhase(boolean quiet) {
        if (phase == PHASE_WORK) {
            phase = round >= roundsBeforeLong ? PHASE_LONG : PHASE_SHORT;
        } else if (phase == PHASE_SHORT) {
            round++;
            phase = PHASE_WORK;
        } else {
            round = 1;
            cycle++;
            phase = PHASE_WORK;
        }
        long now = SystemClock.elapsedRealtime();
        totalMs = phaseMs(phase);
        accumulatedMs = 0L;
        baseElapsed = now;
        boolean auto = Prefs.getInt(prefs, Prefs.AUTONEXT) == 1;
        timerRunning = auto;
        waitingStart = !auto;
        promptUntil = 0L;
        if (phase != PHASE_WORK && auto && Prefs.getInt(prefs, Prefs.SKIPPROMPT) == 1) {
            promptUntil = now + 8000L;
        }
        wake();
        if (!quiet) {
            playSound(RingtoneManager.TYPE_NOTIFICATION, false, 3000L, new long[]{0, 250, 150, 250});
        }
    }

    private void update() {
        if (bubble == null) return;
        long now = SystemClock.elapsedRealtime();
        boolean timerSecs = Prefs.getInt(prefs, Prefs.TIMER_SECS) == 1;
        String text;
        String lbl = null;
        float prog = -1f;
        int ringOverride = 0;

        if (mode == Prefs.MODE_CLOCK) {
            int face = Prefs.getInt(prefs, Prefs.CLOCK_FACE);
            if (face != Prefs.FACE_DIGITAL) {
                Calendar cal = Calendar.getInstance();
                float sec = cal.get(Calendar.SECOND) + cal.get(Calendar.MILLISECOND) / 1000f;
                float min = cal.get(Calendar.MINUTE) + sec / 60f;
                float hr = (cal.get(Calendar.HOUR) % 12) + min / 60f;
                bubble.setAnalog(face, hr * 30f, min * 6f, sec * 6f, clockSec, null);
                return;
            }
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
                text = Prefs.fmtTime(el, false, timerSecs);
                prog = (el % 60000L) / 60000f;
                lbl = timerRunning ? null : pausedLabel();
            } else if (mode == Prefs.MODE_COUNTDOWN) {
                long rem = totalMs - el;
                if (timerRunning && rem <= 0L) {
                    onCountdownFinished();
                    rem = 0L;
                }
                if (rem < 0L) rem = 0L;
                text = Prefs.fmtTime(rem, true, timerSecs);
                prog = totalMs > 0L ? rem / (float) totalMs : 0f;
                lbl = alarming ? "DONE" : (timerRunning ? null : pausedLabel());
            } else {
                long rem = totalMs - el;
                if (timerRunning && rem <= 0L) {
                    nextPhase(false);
                    el = accumulatedMs + (timerRunning ? now - baseElapsed : 0L);
                    rem = totalMs - el;
                }
                if (rem < 0L) rem = 0L;
                text = Prefs.fmtTime(rem, true, timerSecs);
                prog = totalMs > 0L ? rem / (float) totalMs : 0f;
                if (!timerRunning) {
                    lbl = waitingStart ? "TAP TO START" : pausedLabel();
                } else if (phase == PHASE_WORK) {
                    lbl = "FOCUS " + round + "/" + roundsBeforeLong;
                    if (Prefs.getInt(prefs, Prefs.CYCLES) == 1) lbl += " · C" + cycle;
                } else if (now < promptUntil) {
                    lbl = "SKIP BREAK?";
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
        boolean loud = Prefs.getInt(prefs, Prefs.LOUD) == 1;
        if (Prefs.getInt(prefs, Prefs.SOUND) == 1 && soundAllowed()) {
            try {
                Uri uri = RingtoneManager.getDefaultUri(type);
                if (uri == null) uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
                ringtone = RingtoneManager.getRingtone(this, uri);
                if (ringtone != null) {
                    ringtone.setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(loud ? AudioAttributes.USAGE_ALARM : AudioAttributes.USAGE_MEDIA)
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

    /** Quiet when the phone is on silent/vibrate or Do Not Disturb, unless Loud alarm is on. */
    private boolean soundAllowed() {
        if (Prefs.getInt(prefs, Prefs.LOUD) == 1) return true;
        try {
            AudioManager am = (AudioManager) getSystemService(AUDIO_SERVICE);
            if (am != null && am.getRingerMode() != AudioManager.RINGER_MODE_NORMAL) return false;
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (nm != null) {
                int f = nm.getCurrentInterruptionFilter();
                if (f != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
                        && f != NotificationManager.INTERRUPTION_FILTER_ALL) {
                    return false;
                }
            }
        } catch (Exception ignored) {
        }
        return true;
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
cat > 'app/src/main/java/com/floaty/timer/FlowLayout.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;

/** Lays children out left to right and wraps to a new row when the row is full. */
class FlowLayout extends ViewGroup {
    private int gap;

    FlowLayout(Context c, int gapPx) {
        super(c);
        gap = gapPx;
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        int maxW = MeasureSpec.getSize(widthSpec) - getPaddingLeft() - getPaddingRight();
        int x = 0;
        int y = 0;
        int lineH = 0;
        for (int i = 0; i < getChildCount(); i++) {
            View ch = getChildAt(i);
            if (ch.getVisibility() == View.GONE) continue;
            ch.measure(MeasureSpec.makeMeasureSpec(maxW, MeasureSpec.AT_MOST),
                    MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
            int cw = ch.getMeasuredWidth();
            int chh = ch.getMeasuredHeight();
            if (x > 0 && x + cw > maxW) {
                x = 0;
                y += lineH + gap;
                lineH = 0;
            }
            x += cw + gap;
            lineH = Math.max(lineH, chh);
        }
        int total = y + lineH + getPaddingTop() + getPaddingBottom();
        setMeasuredDimension(MeasureSpec.getSize(widthSpec), total);
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        int maxW = r - l - getPaddingLeft() - getPaddingRight();
        int x = 0;
        int y = 0;
        int lineH = 0;
        for (int i = 0; i < getChildCount(); i++) {
            View ch = getChildAt(i);
            if (ch.getVisibility() == View.GONE) continue;
            int cw = ch.getMeasuredWidth();
            int chh = ch.getMeasuredHeight();
            if (x > 0 && x + cw > maxW) {
                x = 0;
                y += lineH + gap;
                lineH = 0;
            }
            int left = getPaddingLeft() + x;
            int top = getPaddingTop() + y;
            ch.layout(left, top, left + cw, top + chh);
            x += cw + gap;
            lineH = Math.max(lineH, chh);
        }
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/GuideActivity.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Four-step quick guide shown on first launch and from Settings. */
public class GuideActivity extends Activity {
    private static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT;
    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;
    private static final int STEPS = 4;

    private SharedPreferences p;
    private Ui ui;
    private LinearLayout art;
    private TextView stepLabel;
    private TextView title;
    private TextView body;
    private LinearLayout dots;
    private TextView skip;
    private TextView next;
    private int step = 0;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        p = Prefs.get(this);
        ui = new Ui(this, p);
        ui.styleWindow(this);

        FrameLayout frame = new FrameLayout(this);
        frame.setBackgroundColor(ui.surface);
        int maxW = Math.min(getResources().getDisplayMetrics().widthPixels, ui.dp(520));
        LinearLayout card = ui.vertical();
        card.setPadding(ui.dp(20), ui.dp(20), ui.dp(20), ui.dp(20));
        FrameLayout.LayoutParams clp = new FrameLayout.LayoutParams(maxW, MATCH, Gravity.CENTER_HORIZONTAL);
        frame.addView(card, clp);

        art = new LinearLayout(this);
        art.setOrientation(LinearLayout.VERTICAL);
        art.setGravity(Gravity.CENTER);
        art.setBackground(ui.rounded(ui.container, 24));
        art.setPadding(ui.dp(16), ui.dp(16), ui.dp(16), ui.dp(16));
        card.addView(art, new LinearLayout.LayoutParams(MATCH, 0, 1.2f));

        stepLabel = ui.medium("", 12, ui.primary);
        stepLabel.setLetterSpacing(0.08f);
        card.addView(stepLabel, ui.lp(MATCH, WRAP, 4, 18, 0, 0));
        title = ui.medium("", 24, ui.onSurface);
        card.addView(title, ui.lp(MATCH, WRAP, 4, 6, 0, 0));
        body = ui.text("", 15, ui.variant);
        body.setLineSpacing(ui.dp(3), 1f);
        card.addView(body, ui.lp(MATCH, WRAP, 4, 8, 4, 0));
        card.addView(new View(this), new LinearLayout.LayoutParams(MATCH, 0, 0.4f));

        LinearLayout nav = ui.horizontal();
        skip = ui.medium("Skip", 14, ui.primary);
        skip.setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10));
        skip.setOnClickListener(v -> finish());
        nav.addView(skip, new LinearLayout.LayoutParams(ui.dp(84), WRAP));
        dots = ui.horizontal();
        dots.setGravity(Gravity.CENTER);
        nav.addView(dots, new LinearLayout.LayoutParams(0, WRAP, 1f));
        next = ui.medium("Next", 14, ui.onPrimary);
        next.setGravity(Gravity.CENTER);
        next.setBackground(ui.rounded(ui.primary, 20));
        next.setOnClickListener(v -> {
            if (step >= STEPS - 1) {
                finish();
            } else {
                step++;
                show();
            }
        });
        nav.addView(next, new LinearLayout.LayoutParams(ui.dp(84), ui.dp(40)));
        card.addView(nav, new LinearLayout.LayoutParams(MATCH, WRAP));

        setContentView(frame);
        show();
    }

    private void show() {
        stepLabel.setText("STEP " + (step + 1) + " OF " + STEPS);
        art.removeAllViews();
        if (step == 0) {
            title.setText("Allow floating");
            body.setText("Android asks once. Turn on \"Display over other apps\" so the timer can sit above "
                    + "your other apps. Watchu collects no data and has no internet access.");
            LinearLayout row = ui.horizontal();
            row.setBackground(ui.rounded(ui.high, 20));
            row.setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(14));
            LinearLayout t = ui.vertical();
            t.addView(ui.text("Display over other apps", 15, ui.onSurface));
            t.addView(ui.text("Allow Watchu", 12, ui.variant));
            row.addView(t, new LinearLayout.LayoutParams(0, WRAP, 1f));
            android.widget.Switch sw = ui.makeSwitch(true, null);
            sw.setClickable(false);
            row.addView(sw);
            art.addView(row, new LinearLayout.LayoutParams(MATCH, WRAP));
        } else if (step == 1) {
            title.setText("Start your timer");
            body.setText("Pick Timer, Stopwatch, Pomodoro or Clock, then tap Start floating timer. "
                    + "The bubble stays on top while you use other apps.");
            BubbleView bv = new BubbleView(this);
            bv.applyPrefs(p);
            bv.setState("25:00", "FOCUS 1/4", 0.65f, 0, false);
            art.addView(bv, new LinearLayout.LayoutParams(WRAP, WRAP));
        } else if (step == 2) {
            title.setText("Control the bubble");
            body.setText("Everything works right on the bubble. In Pomodoro, tap it while it says "
                    + "\"Skip break?\" to jump straight back to focus.");
            addGesture("Tap", "pause or resume");
            addGesture("Hold", "reset");
            addGesture("Drag", "move it anywhere");
            addGesture("Drop on ✕", "close it");
        } else {
            title.setText("Make it yours");
            body.setText("Change colours, shape and size in Style. Save your own presets on the Timer tab. "
                    + "Watchu is free for life.");
            LinearLayout dotsRow = ui.horizontal();
            int[][] cols = {{0xFF14161C, 0xFF14161C, 0xFF7C9CFF}, {0xFFFF7A59, 0xFFB5179E, 0xFFFFE066},
                    {0xFF0F9B8E, 0xFF5B2A86, 0xFFB6F7E4}, {0xFF0C2233, 0xFF0E5A7E, 0xFF4DD0E1}};
            for (int[] c : cols) {
                GradientDrawable g = new GradientDrawable();
                g.setShape(GradientDrawable.OVAL);
                g.setOrientation(GradientDrawable.Orientation.TL_BR);
                g.setColors(new int[]{c[0], c[1]});
                g.setStroke(ui.dp(2), c[2]);
                View v = new View(this);
                v.setBackground(g);
                dotsRow.addView(v, ui.lp(ui.dp(44), ui.dp(44), 6, 0, 6, 0));
            }
            art.addView(dotsRow, new LinearLayout.LayoutParams(WRAP, WRAP));
        }
        dots.removeAllViews();
        for (int i = 0; i < STEPS; i++) {
            View d = new View(this);
            d.setBackground(ui.rounded(i == step ? ui.primary : ui.line, 3));
            dots.addView(d, ui.lp(i == step ? ui.dp(18) : ui.dp(6), ui.dp(6), 3, 0, 3, 0));
        }
        next.setText(step == STEPS - 1 ? "Got it" : "Next");
        skip.setVisibility(step == STEPS - 1 ? View.INVISIBLE : View.VISIBLE);
    }

    private void addGesture(String verb, String what) {
        LinearLayout row = ui.horizontal();
        View dot = new View(this);
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(ui.secC);
        dot.setBackground(g);
        row.addView(dot, ui.lp(ui.dp(14), ui.dp(14), 4, 0, 14, 0));
        TextView v = ui.medium(verb, 16, ui.onSurface);
        row.addView(v);
        row.addView(ui.text("  " + what, 16, ui.variant));
        art.addView(row, ui.lp(MATCH, WRAP, 12, 9, 12, 9));
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
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/** Main screen: Timer, Style and Stats tabs with a pinned start button. */
public class MainActivity extends Activity {
    private static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT;
    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;

    private static final int N_NONE = 0;
    private static final int N_STYLE = 1;
    private static final int N_CONFIG = 2;

    private static final int[] PALETTE = {
            0xFF14161C, 0xFF000000, 0xFFFFFFFF, 0xFFF4F1EA, 0xFF1F2A44, 0xFF7C9CFF,
            0xFF5BD6A0, 0xFFFFB86B, 0xFFFF6B81, 0xFFB794F6, 0xFFFFE066, 0xFF4DD0E1,
            0xFFFF7A59, 0xFF39FF88, 0xFFE8B4A6, 0xFF9D7BFF
    };

    private static final String[] THEME_NAMES = {
            "Midnight", "Snow", "Mint", "Sunset", "Aurora", "Ocean", "Candy",
            "Neon", "Rose gold", "Forest", "Lava", "Rainbow", "Mono"
    };
    /** Each theme: background, second background, text, accent, background style. */
    private static final int[][] THEMES = {
            {0xFF14161C, 0xFF14161C, 0xFFFFFFFF, 0xFF7C9CFF, Prefs.BGMODE_SOLID},
            {0xFFF7F7F5, 0xFFF7F7F5, 0xFF14161C, 0xFF3B5BDB, Prefs.BGMODE_SOLID},
            {0xFF0F2A24, 0xFF0F2A24, 0xFFE9FFF6, 0xFF5BD6A0, Prefs.BGMODE_SOLID},
            {0xFFFF7A59, 0xFFB5179E, 0xFFFFFFFF, 0xFFFFE066, Prefs.BGMODE_GRADIENT},
            {0xFF0F9B8E, 0xFF5B2A86, 0xFFFFFFFF, 0xFFB6F7E4, Prefs.BGMODE_GRADIENT},
            {0xFF0C2233, 0xFF0E5A7E, 0xFFEAF6FF, 0xFF4DD0E1, Prefs.BGMODE_GRADIENT},
            {0xFFFF8FB1, 0xFF9D7BFF, 0xFFFFFFFF, 0xFFFFF3A3, Prefs.BGMODE_GRADIENT},
            {0xFF05060A, 0xFF05060A, 0xFFE8FFE8, 0xFF39FF88, Prefs.BGMODE_SOLID},
            {0xFFE8B4A6, 0xFFB76E79, 0xFF2B1B1F, 0xFFFFFFFF, Prefs.BGMODE_GRADIENT},
            {0xFF0F3D2E, 0xFF1F7A4C, 0xFFF0FFF4, 0xFFB8F2A0, Prefs.BGMODE_GRADIENT},
            {0xFF1A0505, 0xFF8E1B0E, 0xFFFFF3E0, 0xFFFFB703, Prefs.BGMODE_GRADIENT},
            {0xFF3A3F8F, 0xFF8F3A7A, 0xFFFFFFFF, 0xFFFFFFFF, Prefs.BGMODE_ANIM},
            {0xFF000000, 0xFF000000, 0xFFFFFFFF, 0xFFFFFFFF, Prefs.BGMODE_SOLID}
    };
    private static final int[] RAINBOW = {0xFFFF5F6D, 0xFFFFC371, 0xFF47E1A6, 0xFF5B8DEF};

    private static final String[] COLOR_KEYS = {Prefs.BG, Prefs.BG2, Prefs.FG, Prefs.ACCENT};

    private static int lastTab = 0;

    private SharedPreferences p;
    private Ui ui;
    private int builtTheme;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private LinearLayout topLeft;
    private FrameLayout pageHost;
    private LinearLayout timerBox;
    private LinearLayout styleBox;
    private final View[] pages = new View[3];
    private LinearLayout startBar;
    private ImageView startIcon;
    private TextView startText;
    private final View[] navPill = new View[3];
    private final ImageView[] navIcon = new ImageView[3];
    private final TextView[] navLabel = new TextView[3];
    private BubbleView previewT;
    private BubbleView previewS;
    private int tab;
    private boolean editPresets = false;
    private int colorTarget = 0;

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            updateStartBtn();
            if (Prefs.getInt(p, Prefs.MODE) == Prefs.MODE_CLOCK) refreshPreview();
            handler.postDelayed(this, 1000L);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        p = Prefs.get(this);
        tab = lastTab;
        build();
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }
        if (Prefs.getInt(p, Prefs.GUIDE_SEEN) == 0) {
            p.edit().putInt(Prefs.GUIDE_SEEN, 1).apply();
            startActivity(new Intent(this, GuideActivity.class));
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (Ui.resolveTheme(this, p) != builtTheme) {
            recreate();
            return;
        }
        refreshPreview();
        handler.removeCallbacks(poll);
        handler.post(poll);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(poll);
        super.onPause();
    }

    // ------------------------------------------------------------ frame

    private int dp(float v) {
        return ui.dp(v);
    }

    private LinearLayout.LayoutParams lp(int w, int h, float l, float t, float r, float bt) {
        return ui.lp(w, h, l, t, r, bt);
    }

    private void build() {
        ui = new Ui(this, p);
        builtTheme = ui.themeId;

        Window w = getWindow();
        w.setStatusBarColor(ui.surface);
        w.setNavigationBarColor(ui.container);
        int flags = 0;
        if (!ui.dark) {
            flags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        }
        w.getDecorView().setSystemUiVisibility(flags);

        FrameLayout frame = new FrameLayout(this);
        frame.setBackgroundColor(ui.surface);

        int maxW = Math.min(getResources().getDisplayMetrics().widthPixels, dp(640));
        LinearLayout column = ui.vertical();
        frame.addView(column, new FrameLayout.LayoutParams(maxW, MATCH, Gravity.CENTER_HORIZONTAL));

        // top bar
        LinearLayout top = ui.horizontal();
        top.setPadding(dp(16), dp(6), dp(8), dp(6));
        topLeft = ui.horizontal();
        top.addView(topLeft, new LinearLayout.LayoutParams(0, WRAP, 1f));
        ImageView gear = ui.icon(R.drawable.ic_gear, 24, ui.variant);
        gear.setPadding(dp(8), dp(8), dp(8), dp(8));
        gear.setContentDescription("Settings");
        gear.setOnClickListener(v -> startActivity(new Intent(this, SettingsActivity.class)));
        top.addView(gear, new LinearLayout.LayoutParams(dp(44), dp(44)));
        column.addView(top, new LinearLayout.LayoutParams(MATCH, dp(56)));

        // pages
        pageHost = new FrameLayout(this);
        column.addView(pageHost, new LinearLayout.LayoutParams(MATCH, 0, 1f));
        pages[0] = buildTimerPage();
        pages[1] = buildStylePage();
        pages[2] = buildStatsPage();
        for (View v : pages) pageHost.addView(v, new FrameLayout.LayoutParams(MATCH, MATCH));

        // start bar
        startBar = ui.horizontal();
        startBar.setGravity(Gravity.CENTER);
        startIcon = new ImageView(this);
        startIcon.setLayoutParams(new LinearLayout.LayoutParams(dp(22), dp(22)));
        startBar.addView(startIcon);
        startText = ui.medium("Start floating timer", 16, ui.onPrimary);
        startBar.addView(startText, lp(WRAP, WRAP, 8, 0, 0, 0));
        startBar.setOnClickListener(v -> onStartStop());
        FrameLayout startWrap = new FrameLayout(this);
        startWrap.setPadding(dp(16), dp(8), dp(16), dp(12));
        startWrap.addView(startBar, new FrameLayout.LayoutParams(MATCH, dp(56)));
        column.addView(startWrap, new LinearLayout.LayoutParams(MATCH, WRAP));

        // navigation bar
        LinearLayout nav = ui.horizontal();
        nav.setBackgroundColor(ui.container);
        int[] icons = {R.drawable.ic_nav_timer, R.drawable.ic_nav_style, R.drawable.ic_nav_stats};
        String[] names = {"Timer", "Style", "Stats"};
        for (int i = 0; i < 3; i++) {
            final int idx = i;
            LinearLayout item = ui.vertical();
            item.setGravity(Gravity.CENTER_HORIZONTAL);
            item.setPadding(0, dp(12), 0, dp(14));
            FrameLayout pillBox = new FrameLayout(this);
            View pill = new View(this);
            navPill[i] = pill;
            pillBox.addView(pill, new FrameLayout.LayoutParams(dp(64), dp(32), Gravity.CENTER));
            navIcon[i] = ui.icon(icons[i], 24, ui.variant);
            pillBox.addView(navIcon[i], new FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER));
            item.addView(pillBox, new LinearLayout.LayoutParams(dp(64), dp(32)));
            navLabel[i] = ui.medium(names[i], 12, ui.variant);
            item.addView(navLabel[i], lp(WRAP, WRAP, 0, 4, 0, 0));
            item.setOnClickListener(v -> showTab(idx));
            nav.addView(item, new LinearLayout.LayoutParams(0, WRAP, 1f));
        }
        column.addView(nav, new LinearLayout.LayoutParams(MATCH, WRAP));

        setContentView(frame);
        showTab(tab);
        refreshPreview();
        updateStartBtn();
    }

    private void showTab(int t) {
        tab = t;
        lastTab = t;
        for (int i = 0; i < 3; i++) {
            pages[i].setVisibility(i == t ? View.VISIBLE : View.GONE);
            boolean on = i == t;
            navPill[i].setBackground(on ? ui.rounded(ui.secC, 16) : null);
            navIcon[i].setImageTintList(ColorStateList.valueOf(on ? ui.onSecC : ui.variant));
            navLabel[i].setTextColor(on ? ui.onSurface : ui.variant);
        }
        View sw = startBar.getParent() instanceof View ? (View) startBar.getParent() : null;
        if (sw != null) sw.setVisibility(t == 2 ? View.GONE : View.VISIBLE);
        topLeft.removeAllViews();
        if (t == 0) {
            ImageView logo = new ImageView(this);
            logo.setImageResource(R.drawable.ic_logo);
            topLeft.addView(logo, new LinearLayout.LayoutParams(dp(36), dp(36)));
            ImageView wmMain = new ImageView(this);
            wmMain.setImageResource(R.drawable.wm_main);
            wmMain.setImageTintList(ColorStateList.valueOf(ui.onSurface));
            wmMain.setContentDescription("Watchu");
            topLeft.addView(wmMain, lp(WRAP, WRAP, 10, 0, 0, 0));
            ImageView wmU = new ImageView(this);
            wmU.setImageResource(R.drawable.wm_u);
            wmU.setImageTintList(ColorStateList.valueOf(ui.primary));
            topLeft.addView(wmU, lp(WRAP, WRAP, 0, 0, 0, 0));
        } else {
            topLeft.addView(ui.medium(t == 1 ? "Style" : "Stats", 22, ui.onSurface));
        }
    }

    // ------------------------------------------------------------ small builders

    private LinearLayout card() {
        LinearLayout c = ui.vertical();
        c.setBackground(ui.rounded(ui.container, 24));
        c.setPadding(dp(16), dp(4), dp(16), dp(4));
        return c;
    }

    private View divider() {
        View v = new View(this);
        v.setBackgroundColor(ui.line);
        v.setLayoutParams(new LinearLayout.LayoutParams(MATCH, dp(1)));
        return v;
    }

    private FrameLayout makePreviewCard(boolean timerTab) {
        FrameLayout card = new FrameLayout(this);
        card.setBackground(ui.rounded(ui.dark ? ui.high : ui.container, 28));
        card.setMinimumHeight(dp(150));
        TextView lbl = ui.medium("LIVE PREVIEW", 12, ui.variant);
        lbl.setLetterSpacing(0.06f);
        card.addView(lbl, new FrameLayout.LayoutParams(WRAP, WRAP, Gravity.TOP | Gravity.START));
        ((FrameLayout.LayoutParams) lbl.getLayoutParams()).setMargins(dp(18), dp(12), 0, 0);
        BubbleView bv = new BubbleView(this);
        FrameLayout.LayoutParams blp = new FrameLayout.LayoutParams(WRAP, WRAP, Gravity.CENTER);
        blp.setMargins(0, dp(26), 0, dp(14));
        card.addView(bv, blp);
        if (timerTab) {
            previewT = bv;
        } else {
            previewS = bv;
        }
        return card;
    }

    private LinearLayout labelled(String label, View control) {
        LinearLayout row = ui.horizontal();
        row.addView(ui.text(label, 14, ui.variant), new LinearLayout.LayoutParams(dp(64), WRAP));
        row.addView(control, new LinearLayout.LayoutParams(0, dp(40), 1f));
        return row;
    }

    // ------------------------------------------------------------ timer tab

    private View buildTimerPage() {
        ScrollView sv = new ScrollView(this);
        sv.setFillViewport(true);
        timerBox = ui.vertical();
        timerBox.setPadding(dp(16), dp(4), dp(16), dp(12));
        sv.addView(timerBox, new FrameLayout.LayoutParams(MATCH, WRAP));
        fillTimer();
        return sv;
    }

    private void fillTimer() {
        timerBox.removeAllViews();
        timerBox.addView(makePreviewCard(true), lp(MATCH, WRAP, 0, 0, 0, 14));
        buildPresets(timerBox);

        int mode = Prefs.getInt(p, Prefs.MODE);
        LinearLayout seg = ui.segmented(new String[]{"Timer", "Stopwatch", "Pomodoro", "Clock"}, mode,
                v -> {
                    p.edit().putInt(Prefs.MODE, v).apply();
                    fillTimer();
                    changed(N_CONFIG);
                });
        timerBox.addView(seg, lp(MATCH, dp(40), 0, 6, 0, 12));

        LinearLayout card = card();
        if (mode == Prefs.MODE_COUNTDOWN) {
            card.addView(stepper("Minutes", Prefs.CD_MIN, 0, 999, 1, "min", N_CONFIG));
            card.addView(divider());
            card.addView(stepper("Seconds", Prefs.CD_SEC, 0, 59, 5, "sec", N_CONFIG));
        } else if (mode == Prefs.MODE_STOPWATCH) {
            TextView t = ui.text("Counts up from 00:00. Tap the bubble to pause or resume, hold it to reset.",
                    15, ui.variant);
            t.setPadding(0, dp(14), 0, dp(14));
            card.addView(t);
        } else if (mode == Prefs.MODE_POMODORO) {
            card.addView(stepper("Focus", Prefs.POMO_WORK, 1, 180, 1, "min", N_CONFIG));
            card.addView(divider());
            card.addView(stepper("Short break", Prefs.POMO_SHORT, 1, 60, 1, "min", N_CONFIG));
            card.addView(divider());
            card.addView(stepper("Long break", Prefs.POMO_LONG, 1, 120, 1, "min", N_CONFIG));
            card.addView(divider());
            card.addView(stepper("Rounds before long break", Prefs.POMO_ROUNDS, 1, 12, 1, "", N_CONFIG));
        } else {
            int face = Prefs.getInt(p, Prefs.CLOCK_FACE);
            LinearLayout faceRow = ui.horizontal();
            faceRow.setMinimumHeight(dp(60));
            faceRow.addView(ui.text("Style", 16, ui.onSurface), new LinearLayout.LayoutParams(0, WRAP, 1f));
            faceRow.addView(ui.segmented(new String[]{"Digital", "Analog"}, face == 0 ? 0 : 1, v -> {
                p.edit().putInt(Prefs.CLOCK_FACE, v == 0 ? 0 : 1).apply();
                fillTimer();
                changed(N_STYLE);
            }), new LinearLayout.LayoutParams(dp(190), dp(40)));
            card.addView(faceRow);
            card.addView(divider());
            if (face == 0) {
                card.addView(ui.switchRow("24-hour clock", null, Prefs.getInt(p, Prefs.CLOCK_24) == 1,
                        (b, on) -> {
                            p.edit().putInt(Prefs.CLOCK_24, on ? 1 : 0).apply();
                            changed(N_STYLE);
                        }));
            } else {
                LinearLayout faceRow2 = ui.horizontal();
                faceRow2.setMinimumHeight(dp(60));
                faceRow2.addView(ui.text("Watch face", 16, ui.onSurface), new LinearLayout.LayoutParams(0, WRAP, 1f));
                faceRow2.addView(ui.segmented(new String[]{"Minimal", "Numbers"}, face == 2 ? 1 : 0, v -> {
                    p.edit().putInt(Prefs.CLOCK_FACE, v == 1 ? 2 : 1).apply();
                    changed(N_STYLE);
                }), new LinearLayout.LayoutParams(dp(190), dp(40)));
                card.addView(faceRow2);
            }
            card.addView(divider());
            card.addView(ui.switchRow("Show seconds", null, Prefs.getInt(p, Prefs.CLOCK_SEC) == 1,
                    (b, on) -> {
                        p.edit().putInt(Prefs.CLOCK_SEC, on ? 1 : 0).apply();
                        changed(N_STYLE);
                    }));
        }
        timerBox.addView(card, lp(MATCH, WRAP, 0, 0, 0, 0));
        refreshPreview();
    }

    /** One row: label, minus button, fixed-width value, plus button. Every row lines up. */
    private LinearLayout stepper(String label, final String key, final int min, final int max,
                                 final int step, final String unit, final int notify) {
        LinearLayout row = ui.horizontal();
        row.setMinimumHeight(dp(56));
        row.addView(ui.text(label, 16, ui.onSurface), new LinearLayout.LayoutParams(0, WRAP, 1f));
        final TextView value = ui.medium(valueText(Prefs.getInt(p, key), unit), 16, ui.onSurface);
        value.setGravity(Gravity.CENTER);
        TextView minus = ui.stepButton("−", () -> bump(key, -step, min, max, value, unit, notify));
        TextView plus = ui.stepButton("+", () -> bump(key, step, min, max, value, unit, notify));
        row.addView(minus, new LinearLayout.LayoutParams(dp(36), dp(36)));
        row.addView(value, new LinearLayout.LayoutParams(dp(72), WRAP));
        row.addView(plus, new LinearLayout.LayoutParams(dp(36), dp(36)));
        return row;
    }

    private String valueText(int v, String unit) {
        return unit.isEmpty() ? String.valueOf(v) : v + " " + unit;
    }

    private void bump(String key, int delta, int min, int max, TextView value, String unit, int notify) {
        int v = Prefs.getInt(p, key) + delta;
        if (v < min) v = min;
        if (v > max) v = max;
        p.edit().putInt(key, v).apply();
        value.setText(valueText(v, unit));
        changed(notify);
    }

    // ------------------------------------------------------------ presets

    private void buildPresets(LinearLayout box) {
        LinearLayout head = ui.horizontal();
        head.addView(ui.medium("Presets", 14, ui.variant), new LinearLayout.LayoutParams(0, WRAP, 1f));
        head.addView(ui.textButton("Save current", R.drawable.ic_plus, v -> askName("Save current setup",
                "My preset", name -> saveCurrent(name))));
        head.addView(ui.textButton(editPresets ? "Done" : "Edit",
                editPresets ? R.drawable.ic_check : R.drawable.ic_edit, v -> {
                    editPresets = !editPresets;
                    fillTimer();
                }));
        box.addView(head, lp(MATCH, WRAP, 0, 0, 0, 4));

        FlowLayout flow = new FlowLayout(this, dp(8));
        List<String> hidden = Presets.hidden(p);
        for (final Presets.Preset x : Presets.builtIns()) {
            if (hidden.contains(x.name)) continue;
            flow.addView(presetChip(x));
        }
        for (final Presets.Preset x : Presets.saved(p)) {
            flow.addView(presetChip(x));
        }
        if (editPresets && !hidden.isEmpty()) {
            TextView restore = ui.chip("Restore hidden", false, true);
            restore.setOnClickListener(v -> {
                Presets.writeHidden(p, new java.util.ArrayList<String>());
                fillTimer();
            });
            flow.addView(restore);
        }
        box.addView(flow, lp(MATCH, WRAP, 0, 0, 0, 6));
        if (editPresets) {
            box.addView(ui.text("Tap a preset to rename, delete or hide it.", 12, ui.variant),
                    lp(MATCH, WRAP, 0, 0, 0, 4));
        }
    }

    private View presetChip(final Presets.Preset x) {
        boolean sel = !editPresets && Presets.matches(p, x);
        TextView c = ui.chip(x.name, sel, editPresets);
        c.setOnClickListener(v -> {
            if (editPresets) {
                presetOptions(x);
            } else {
                Presets.apply(p, x);
                fillTimer();
                changed(N_CONFIG);
            }
        });
        return c;
    }

    private void presetOptions(final Presets.Preset x) {
        if (x.builtIn) {
            dialog().setTitle(x.name)
                    .setItems(new String[]{"Hide this preset"}, (d, which) -> {
                        List<String> h = Presets.hidden(p);
                        h.add(x.name);
                        Presets.writeHidden(p, h);
                        fillTimer();
                    }).setNegativeButton("Cancel", null).show();
        } else {
            dialog().setTitle(x.name)
                    .setItems(new String[]{"Rename", "Delete"}, (d, which) -> {
                        if (which == 0) {
                            askName("Rename preset", x.name, name -> {
                                List<Presets.Preset> list = Presets.saved(p);
                                for (Presets.Preset s : list) {
                                    if (s.name.equals(x.name)) s.name = Presets.clean(name);
                                }
                                Presets.writeSaved(p, list);
                                fillTimer();
                            });
                        } else {
                            List<Presets.Preset> list = Presets.saved(p);
                            for (int i = list.size() - 1; i >= 0; i--) {
                                if (list.get(i).name.equals(x.name)) list.remove(i);
                            }
                            Presets.writeSaved(p, list);
                            fillTimer();
                        }
                    }).setNegativeButton("Cancel", null).show();
        }
    }

    private void saveCurrent(String raw) {
        String name = Presets.clean(raw);
        List<Presets.Preset> list = Presets.saved(p);
        for (int i = list.size() - 1; i >= 0; i--) {
            if (list.get(i).name.equals(name)) list.remove(i);
        }
        if (list.size() >= 12) {
            Toast.makeText(this, "You can keep up to 12 saved presets. Delete one first.",
                    Toast.LENGTH_LONG).show();
            return;
        }
        list.add(Presets.current(p, name));
        Presets.writeSaved(p, list);
        fillTimer();
    }

    private interface StringCb {
        void on(String s);
    }

    private AlertDialog.Builder dialog() {
        return new AlertDialog.Builder(this, ui.dark
                ? android.R.style.Theme_DeviceDefault_Dialog_Alert
                : android.R.style.Theme_DeviceDefault_Light_Dialog_Alert);
    }

    private void askName(String title, String initial, final StringCb cb) {
        final EditText et = new EditText(this);
        et.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        et.setSingleLine(true);
        et.setText(initial);
        et.setSelectAllOnFocus(true);
        FrameLayout box = new FrameLayout(this);
        box.setPadding(dp(20), dp(8), dp(20), 0);
        box.addView(et, new FrameLayout.LayoutParams(MATCH, WRAP));
        dialog().setTitle(title).setView(box)
                .setPositiveButton("Save", (d, which) -> cb.on(et.getText().toString()))
                .setNegativeButton("Cancel", null).show();
    }

    // ------------------------------------------------------------ style tab

    private View buildStylePage() {
        LinearLayout page = ui.vertical();
        LinearLayout.LayoutParams plp = lp(MATCH, WRAP, 16, 4, 16, 8);
        page.addView(makePreviewCard(false), plp);
        ScrollView sv = new ScrollView(this);
        styleBox = ui.vertical();
        styleBox.setPadding(dp(16), dp(2), dp(16), dp(12));
        sv.addView(styleBox, new FrameLayout.LayoutParams(MATCH, WRAP));
        page.addView(sv, new LinearLayout.LayoutParams(MATCH, 0, 1f));
        fillStyle();
        return page;
    }

    private void fillStyle() {
        styleBox.removeAllViews();

        // themes
        styleBox.addView(ui.medium("Themes", 14, ui.variant), lp(MATCH, WRAP, 0, 4, 0, 6));
        HorizontalScrollView hs = new HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        LinearLayout row = ui.horizontal();
        row.setGravity(Gravity.TOP);
        for (int i = 0; i < THEMES.length; i++) {
            final int idx = i;
            row.addView(themeItem(idx), lp(dp(56), WRAP, 0, 0, 4, 0));
        }
        hs.addView(row);
        styleBox.addView(hs, lp(MATCH, WRAP, 0, 0, 0, 10));

        // shape
        styleBox.addView(labelled("Shape", shapeSegment()), lp(MATCH, WRAP, 0, 0, 0, 10));

        // font
        Typeface[] faces = {
                Typeface.create("sans-serif-light", Typeface.NORMAL),
                Typeface.create("sans-serif", Typeface.NORMAL),
                Typeface.create("sans-serif", Typeface.BOLD),
                Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)};
        styleBox.addView(labelled("Font", ui.segmented(new String[]{"Thin", "Regular", "Bold", "Digital"},
                faces, Prefs.getInt(p, Prefs.FONT), v -> {
                    p.edit().putInt(Prefs.FONT, v).apply();
                    changed(N_STYLE);
                })), lp(MATCH, WRAP, 0, 0, 0, 10));

        // ring
        styleBox.addView(labelled("Ring", ui.segmented(new String[]{"Off", "Thin", "Medium", "Thick"},
                Prefs.getInt(p, Prefs.RING), v -> {
                    p.edit().putInt(Prefs.RING, v).apply();
                    changed(N_STYLE);
                })), lp(MATCH, WRAP, 0, 0, 0, 10));

        // fill
        styleBox.addView(labelled("Fill", ui.segmented(new String[]{"Solid", "Gradient", "Animated"},
                Prefs.getInt(p, Prefs.BGMODE), v -> {
                    p.edit().putInt(Prefs.BGMODE, v).apply();
                    if (v != Prefs.BGMODE_GRADIENT && colorTarget == 1) colorTarget = 0;
                    fillStyle();
                    changed(N_STYLE);
                })), lp(MATCH, WRAP, 0, 0, 0, 12));

        // colours
        FlowLayout targets = new FlowLayout(this, dp(8));
        boolean grad = Prefs.getInt(p, Prefs.BGMODE) == Prefs.BGMODE_GRADIENT;
        String[] tn = {"Colour 1", "Colour 2", "Text", "Ring and label"};
        for (int i = 0; i < 4; i++) {
            if (i == 1 && !grad) continue;
            final int idx = i;
            TextView c = ui.chip(tn[i], colorTarget == i, false);
            c.setOnClickListener(v -> {
                colorTarget = idx;
                fillStyle();
            });
            targets.addView(c);
        }
        styleBox.addView(targets, lp(MATCH, WRAP, 0, 0, 0, 8));
        styleBox.addView(swatches(), lp(MATCH, WRAP, 0, 0, 0, 10));

        styleBox.addView(slider("Size", Prefs.SIZE, 60, 240, "dp"), lp(MATCH, WRAP, 0, 0, 0, 2));
        styleBox.addView(slider("Opacity", Prefs.OPACITY, 30, 100, "%"), lp(MATCH, WRAP, 0, 0, 0, 0));
    }

    private View themeItem(final int idx) {
        int[] t = THEMES[idx];
        boolean selected = Prefs.getInt(p, Prefs.BG) == t[0] && Prefs.getInt(p, Prefs.BG2) == t[1]
                && Prefs.getInt(p, Prefs.FG) == t[2] && Prefs.getInt(p, Prefs.ACCENT) == t[3]
                && Prefs.getInt(p, Prefs.BGMODE) == t[4];
        LinearLayout item = ui.vertical();
        item.setGravity(Gravity.CENTER_HORIZONTAL);
        FrameLayout holder = new FrameLayout(this);
        if (selected) {
            GradientDrawable ring = new GradientDrawable();
            ring.setShape(GradientDrawable.OVAL);
            ring.setColor(0x00000000);
            ring.setStroke(dp(2), ui.primary);
            holder.setBackground(ring);
        }
        TextView circle = ui.text("Aa", 13, t[2]);
        circle.setGravity(Gravity.CENTER);
        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.OVAL);
        if (t[4] == Prefs.BGMODE_ANIM) {
            gd.setOrientation(GradientDrawable.Orientation.TL_BR);
            gd.setColors(RAINBOW);
        } else if (t[4] == Prefs.BGMODE_GRADIENT) {
            gd.setOrientation(GradientDrawable.Orientation.TL_BR);
            gd.setColors(new int[]{t[0], t[1]});
        } else {
            gd.setColor(t[0]);
        }
        gd.setStroke(dp(2), t[3]);
        circle.setBackground(gd);
        FrameLayout.LayoutParams clp = new FrameLayout.LayoutParams(dp(40), dp(40), Gravity.CENTER);
        holder.addView(circle, clp);
        item.addView(holder, new LinearLayout.LayoutParams(dp(46), dp(46)));
        TextView name = ui.text(THEME_NAMES[idx], 10, selected ? ui.primary : ui.variant);
        name.setSingleLine(true);
        name.setGravity(Gravity.CENTER);
        item.addView(name, lp(WRAP, WRAP, 0, 2, 0, 0));
        item.setOnClickListener(v -> {
            int[] th = THEMES[idx];
            p.edit().putInt(Prefs.BG, th[0]).putInt(Prefs.BG2, th[1])
                    .putInt(Prefs.FG, th[2]).putInt(Prefs.ACCENT, th[3])
                    .putInt(Prefs.BGMODE, th[4]).apply();
            if (th[4] != Prefs.BGMODE_GRADIENT && colorTarget == 1) colorTarget = 0;
            fillStyle();
            changed(N_STYLE);
        });
        return item;
    }

    private View shapeSegment() {
        final int[] res = {R.drawable.ic_shape_circle, R.drawable.ic_shape_squircle, R.drawable.ic_shape_pill};
        int sel = Prefs.getInt(p, Prefs.SHAPE);
        LinearLayout box = new LinearLayout(this);
        box.setBackground(ui.outlined(0x00000000, ui.outline, 20));
        box.setClipToOutline(true);
        final ImageView[] items = new ImageView[3];
        for (int i = 0; i < 3; i++) {
            final int idx = i;
            ImageView iv = new ImageView(this);
            iv.setImageResource(res[i]);
            iv.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
            iv.setPadding(dp(8), dp(8), dp(8), dp(8));
            items[i] = iv;
            if (i > 0) {
                View sep = new View(this);
                sep.setBackgroundColor(ui.outline);
                box.addView(sep, new LinearLayout.LayoutParams(dp(1), MATCH));
            }
            box.addView(iv, new LinearLayout.LayoutParams(0, MATCH, 1f));
            iv.setOnClickListener(v -> {
                p.edit().putInt(Prefs.SHAPE, idx).apply();
                paintShapes(items, idx);
                changed(N_STYLE);
            });
        }
        paintShapes(items, sel);
        return box;
    }

    private void paintShapes(ImageView[] items, int sel) {
        for (int i = 0; i < items.length; i++) {
            boolean on = i == sel;
            items[i].setBackgroundColor(on ? ui.secC : 0x00000000);
            items[i].setImageTintList(ColorStateList.valueOf(on ? ui.onSecC : ui.onSurface));
        }
    }

    private View swatches() {
        FlowLayout flow = new FlowLayout(this, dp(8));
        final String key = COLOR_KEYS[colorTarget];
        int current = Prefs.getInt(p, key);
        for (final int color : PALETTE) {
            boolean sel = color == current;
            View dot = new View(this);
            GradientDrawable g = new GradientDrawable();
            g.setShape(GradientDrawable.OVAL);
            g.setColor(color);
            g.setStroke(dp(sel ? 3 : 1), sel ? ui.primary : ui.outline);
            dot.setBackground(g);
            dot.setLayoutParams(new ViewGroup.LayoutParams(dp(32), dp(32)));
            dot.setOnClickListener(v -> {
                if (tryColor(colorTarget, color)) fillStyle();
            });
            flow.addView(dot);
        }
        TextView custom = ui.medium("+", 18, ui.onSurface);
        custom.setGravity(Gravity.CENTER);
        GradientDrawable cg = new GradientDrawable();
        cg.setShape(GradientDrawable.OVAL);
        cg.setColor(ui.high);
        cg.setStroke(dp(1), ui.outline);
        custom.setBackground(cg);
        custom.setLayoutParams(new ViewGroup.LayoutParams(dp(32), dp(32)));
        custom.setContentDescription("Custom colour");
        custom.setOnClickListener(v -> pickColor(colorTarget));
        flow.addView(custom);
        return flow;
    }

    /** Applies a colour unless it is the same as, or too close to, the colour it sits on. */
    private boolean tryColor(int target, int color) {
        int bg = Prefs.getInt(p, Prefs.BG);
        int bg2 = Prefs.getInt(p, Prefs.BG2);
        int fg = Prefs.getInt(p, Prefs.FG);
        int ac = Prefs.getInt(p, Prefs.ACCENT);
        boolean grad = Prefs.getInt(p, Prefs.BGMODE) == Prefs.BGMODE_GRADIENT;
        boolean bad;
        if (target == 0) {
            bad = Ui.tooClose(fg, color) || Ui.tooClose(ac, color);
        } else if (target == 1) {
            bad = grad && (Ui.tooClose(fg, color) || Ui.tooClose(ac, color));
        } else {
            bad = Ui.tooClose(color, bg) || (grad && Ui.tooClose(color, bg2));
        }
        if (bad) {
            Toast.makeText(this, target >= 2
                            ? "That colour is too close to the background. Pick a different one."
                            : "The background would be too close to the text or ring colour.",
                    Toast.LENGTH_LONG).show();
            return false;
        }
        p.edit().putInt(COLOR_KEYS[target], color).apply();
        changed(N_STYLE);
        return true;
    }

    private View slider(String label, final String key, final int min, final int max, final String unit) {
        LinearLayout row = ui.horizontal();
        row.setMinimumHeight(dp(44));
        row.addView(ui.text(label, 14, ui.variant), new LinearLayout.LayoutParams(dp(64), WRAP));
        SeekBar sb = new SeekBar(this);
        sb.setMax(max - min);
        sb.setProgress(Prefs.getInt(p, key) - min);
        sb.setProgressTintList(ColorStateList.valueOf(ui.primary));
        sb.setThumbTintList(ColorStateList.valueOf(ui.primary));
        sb.setProgressBackgroundTintList(ColorStateList.valueOf(ui.high));
        row.addView(sb, new LinearLayout.LayoutParams(0, WRAP, 1f));
        final TextView val = ui.medium(Prefs.getInt(p, key) + " " + unit, 14, ui.onSurface);
        val.setGravity(Gravity.END);
        row.addView(val, new LinearLayout.LayoutParams(dp(60), WRAP));
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar s, int progress, boolean fromUser) {
                int v = progress + min;
                val.setText(v + " " + unit);
                if (fromUser) {
                    p.edit().putInt(key, v).apply();
                    changed(N_STYLE);
                }
            }

            @Override
            public void onStartTrackingTouch(SeekBar s) {
            }

            @Override
            public void onStopTrackingTouch(SeekBar s) {
            }
        });
        return row;
    }

    /** Colour picker with three sliders (shade, richness, brightness) and a live preview. */
    private void pickColor(final int target) {
        final float[] hsv = new float[3];
        Color.colorToHSV(Prefs.getInt(p, COLOR_KEYS[target]), hsv);

        LinearLayout box = ui.vertical();
        box.setPadding(dp(20), dp(16), dp(20), dp(8));
        final TextView prev = ui.text("", 18, 0xFFFFFFFF);
        prev.setGravity(Gravity.CENTER);
        prev.setPadding(0, dp(22), 0, dp(22));
        box.addView(prev, lp(MATCH, WRAP, 0, 0, 0, 8));

        final ColorSlider hue = new ColorSlider(this);
        final ColorSlider sat = new ColorSlider(this);
        final ColorSlider val = new ColorSlider(this);
        hue.setColors(new int[]{0xFFFF0000, 0xFFFFFF00, 0xFF00FF00, 0xFF00FFFF,
                0xFF0000FF, 0xFFFF00FF, 0xFFFF0000});
        hue.setValue(hsv[0] / 360f);
        sat.setValue(hsv[1]);
        val.setValue(hsv[2]);

        final Runnable refresh = new Runnable() {
            @Override
            public void run() {
                hsv[0] = hue.getValue() * 360f;
                hsv[1] = sat.getValue();
                hsv[2] = val.getValue();
                int c = Color.HSVToColor(hsv);
                sat.setColors(new int[]{
                        Color.HSVToColor(new float[]{hsv[0], 0f, hsv[2]}),
                        Color.HSVToColor(new float[]{hsv[0], 1f, hsv[2]})});
                val.setColors(new int[]{
                        0xFF000000,
                        Color.HSVToColor(new float[]{hsv[0], hsv[1], 1f})});
                prev.setBackground(ui.rounded(c, 14));
                prev.setText(String.format(Locale.US, "#%06X", 0xFFFFFF & c));
                prev.setTextColor(Ui.lum(c) > 0.4 ? 0xFF000000 : 0xFFFFFFFF);
            }
        };
        ColorSlider.Listener listener = new ColorSlider.Listener() {
            @Override
            public void onChange(float value) {
                refresh.run();
            }
        };
        hue.setListener(listener);
        sat.setListener(listener);
        val.setListener(listener);
        refresh.run();

        box.addView(ui.text("Shade", 13, ui.variant));
        box.addView(hue, lp(MATCH, WRAP, 0, 0, 0, 0));
        box.addView(ui.text("Richness", 13, ui.variant));
        box.addView(sat, lp(MATCH, WRAP, 0, 0, 0, 0));
        box.addView(ui.text("Brightness", 13, ui.variant));
        box.addView(val, lp(MATCH, WRAP, 0, 0, 0, 0));

        dialog().setTitle("Pick a colour").setView(box)
                .setPositiveButton("Use colour", (d, which) -> {
                    if (tryColor(target, Color.HSVToColor(hsv))) fillStyle();
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    // ------------------------------------------------------------ stats tab

    private View buildStatsPage() {
        LinearLayout page = ui.vertical();
        page.setGravity(Gravity.CENTER);
        page.setPadding(dp(32), dp(16), dp(32), dp(16));
        ImageView ic = ui.icon(R.drawable.ic_nav_stats, 48, ui.primary);
        page.addView(ic, lp(dp(48), dp(48), 0, 0, 0, 16));
        TextView t = ui.medium("Stats are coming soon", 20, ui.onSurface);
        t.setGravity(Gravity.CENTER);
        page.addView(t);
        TextView s = ui.text("Daily target, a 30-day graph, a calendar and your streak will appear here in the next update.",
                15, ui.variant);
        s.setGravity(Gravity.CENTER);
        page.addView(s, lp(MATCH, WRAP, 0, 8, 0, 0));
        return page;
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
        refreshOne(previewT);
        refreshOne(previewS);
    }

    private void refreshOne(BubbleView pv) {
        if (pv == null) return;
        pv.applyPrefs(p);
        int m = Prefs.getInt(p, Prefs.MODE);
        String t;
        String l = null;
        float prog = 0.7f;
        boolean tsecs = Prefs.getInt(p, Prefs.TIMER_SECS) == 1;
        if (m == Prefs.MODE_COUNTDOWN) {
            int min = Prefs.getInt(p, Prefs.CD_MIN);
            int sec = Prefs.getInt(p, Prefs.CD_SEC);
            t = Prefs.fmtTime((min * 60L + sec) * 1000L, true, tsecs);
        } else if (m == Prefs.MODE_STOPWATCH) {
            t = Prefs.fmtTime(83000L, false, tsecs);
            prog = 0.4f;
        } else if (m == Prefs.MODE_POMODORO) {
            t = Prefs.fmtTime(Prefs.getInt(p, Prefs.POMO_WORK) * 60000L, true, tsecs);
            l = "FOCUS 2/" + Prefs.getInt(p, Prefs.POMO_ROUNDS);
            if (Prefs.getInt(p, Prefs.CYCLES) == 1) l += " · C1";
        } else {
            int face = Prefs.getInt(p, Prefs.CLOCK_FACE);
            if (face != Prefs.FACE_DIGITAL) {
                Calendar cal = Calendar.getInstance();
                float sec = cal.get(Calendar.SECOND) + cal.get(Calendar.MILLISECOND) / 1000f;
                float min = cal.get(Calendar.MINUTE) + sec / 60f;
                float hr = (cal.get(Calendar.HOUR) % 12) + min / 60f;
                pv.setAnalog(face, hr * 30f, min * 6f, sec * 6f,
                        Prefs.getInt(p, Prefs.CLOCK_SEC) == 1, null);
                return;
            }
            boolean h24 = Prefs.getInt(p, Prefs.CLOCK_24) == 1;
            boolean secs = Prefs.getInt(p, Prefs.CLOCK_SEC) == 1;
            String pattern = h24 ? (secs ? "HH:mm:ss" : "HH:mm") : (secs ? "h:mm:ss" : "h:mm");
            Date now = new Date();
            t = new SimpleDateFormat(pattern, Locale.US).format(now);
            l = h24 ? new SimpleDateFormat("EEE", Locale.getDefault()).format(now).toUpperCase(Locale.getDefault())
                    : new SimpleDateFormat("a", Locale.US).format(now).toUpperCase(Locale.US);
            prog = -1f;
        }
        pv.setState(t, l, prog, 0, false);
    }

    private void updateStartBtn() {
        if (startText == null) return;
        if (FloatingService.active) {
            startText.setText("Stop floating timer");
            startText.setTextColor(ui.onSurface);
            startBar.setBackground(ui.rounded(ui.high, 28));
            startIcon.setImageResource(R.drawable.ic_stop);
            startIcon.setImageTintList(ColorStateList.valueOf(ui.onSurface));
        } else {
            startText.setText("Start floating timer");
            startText.setTextColor(ui.onPrimary);
            startBar.setBackground(ui.rounded(ui.primary, 28));
            startIcon.setImageResource(R.drawable.ic_play);
            startIcon.setImageTintList(ColorStateList.valueOf(ui.onPrimary));
        }
    }

    private void onStartStop() {
        if (FloatingService.active) {
            sendToService(FloatingService.ACTION_STOP);
            handler.postDelayed(this::updateStartBtn, 300L);
            return;
        }
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "Turn on \"Display over other apps\" for Watchu, then come back.",
                    Toast.LENGTH_LONG).show();
            startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName())));
            return;
        }
        startForegroundService(new Intent(this, FloatingService.class));
        handler.postDelayed(this::updateStartBtn, 300L);
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

    static final int BGMODE_SOLID = 0;
    static final int BGMODE_GRADIENT = 1;
    static final int BGMODE_ANIM = 2;

    static final int THEME_AUTO = 0;
    static final int THEME_LIGHT = 1;
    static final int THEME_DARK = 2;
    static final int THEME_AMOLED = 3;

    static final int FACE_DIGITAL = 0;
    static final int FACE_MINIMAL = 1;
    static final int FACE_NUMBERS = 2;

    static final String BG2 = "bg2";
    static final String BGMODE = "bg_mode";
    static final String MODE = "mode";
    static final String CD_MIN = "cd_min";
    static final String CD_SEC = "cd_sec";
    static final String POMO_WORK = "pomo_work";
    static final String POMO_SHORT = "pomo_short";
    static final String POMO_LONG = "pomo_long";
    static final String POMO_ROUNDS = "pomo_rounds";
    static final String CLOCK_24 = "clock_24";
    static final String CLOCK_SEC = "clock_sec";
    static final String CLOCK_FACE = "clock_face";
    static final String SHAPE = "shape";
    static final String FONT = "font";
    /** 0 off, 1 thin, 2 medium, 3 thick */
    static final String RING = "ring_w";
    static final String SIZE = "size_dp";
    static final String OPACITY = "opacity";
    static final String BG = "bg";
    static final String FG = "fg";
    static final String ACCENT = "accent";
    static final String SOUND = "sound";
    static final String VIBRATE = "vibrate";
    static final String LOUD = "loud_alarm";
    static final String POS_X = "pos_x";
    static final String POS_Y = "pos_y";

    static final String THEME = "app_theme";
    static final String LOCK = "lock_pos";
    static final String SNAP = "snap_edge";
    static final String FADE = "fade_idle";
    static final String AUTONEXT = "auto_next";
    static final String SKIPPROMPT = "skip_prompt";
    static final String CYCLES = "cycle_counter";
    static final String GUIDE_SEEN = "guide_seen";
    static final String TIMER_SECS = "timer_secs";
    static final String SCREEN_PAUSE = "screen_pause";
    static final String MOTION_PAUSE = "motion_pause";

    /** Saved presets, one per line: name|mode|cdMin|cdSec|work|short|long|rounds */
    static final String PRESETS = "presets_saved";
    /** Hidden built-in presets, names separated by newline. */
    static final String PRESETS_HIDDEN = "presets_hidden";

    /** Formats a duration. With seconds hidden it shows minutes only, like 25m or 1h 05m. */
    static String fmtTime(long ms, boolean roundUp, boolean secs) {
        if (secs) {
            long s = roundUp ? (ms + 999L) / 1000L : ms / 1000L;
            long h = s / 3600L;
            long m = (s % 3600L) / 60L;
            long sec = s % 60L;
            if (h > 0) return String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, sec);
            return String.format(java.util.Locale.US, "%02d:%02d", m, sec);
        }
        long mins = roundUp ? (ms + 59999L) / 60000L : ms / 60000L;
        if (mins >= 60) {
            return String.format(java.util.Locale.US, "%dh %02dm", mins / 60L, mins % 60L);
        }
        return mins + "m";
    }

    static SharedPreferences get(Context c) {
        return c.getApplicationContext().getSharedPreferences("watchu", Context.MODE_PRIVATE);
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
            case CLOCK_FACE: return FACE_DIGITAL;
            case SHAPE: return SHAPE_CIRCLE;
            case FONT: return FONT_REGULAR;
            case RING: return 3;
            case SIZE: return 110;
            case OPACITY: return 95;
            case BG: return 0xFF14161C;
            case BG2: return 0xFF3B2A6B;
            case BGMODE: return BGMODE_SOLID;
            case FG: return 0xFFFFFFFF;
            case ACCENT: return 0xFF7C9CFF;
            case SOUND: return 1;
            case VIBRATE: return 1;
            case LOUD: return 0;
            case POS_X: return -1;
            case POS_Y: return -1;
            case THEME: return THEME_AUTO;
            case LOCK: return 0;
            case SNAP: return 1;
            case FADE: return 1;
            case AUTONEXT: return 1;
            case SKIPPROMPT: return 1;
            case CYCLES: return 1;
            case GUIDE_SEEN: return 0;
            case TIMER_SECS: return 1;
            case SCREEN_PAUSE: return 0;
            case MOTION_PAUSE: return 0;
            default: return 0;
        }
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/Presets.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.List;

/** Built-in and saved presets. A preset is a full timer setup. */
final class Presets {
    private Presets() { }

    static final class Preset {
        String name;
        int mode;
        int cdMin;
        int cdSec;
        int work;
        int shortBreak;
        int longBreak;
        int rounds;
        boolean builtIn;

        Preset(String name, int mode, int cdMin, int cdSec, int work, int shortBreak,
               int longBreak, int rounds, boolean builtIn) {
            this.name = name;
            this.mode = mode;
            this.cdMin = cdMin;
            this.cdSec = cdSec;
            this.work = work;
            this.shortBreak = shortBreak;
            this.longBreak = longBreak;
            this.rounds = rounds;
            this.builtIn = builtIn;
        }
    }

    static List<Preset> builtIns() {
        List<Preset> l = new ArrayList<>();
        l.add(new Preset("Study 25/5", Prefs.MODE_POMODORO, 10, 0, 25, 5, 15, 4, true));
        l.add(new Preset("Deep work 50/10", Prefs.MODE_POMODORO, 10, 0, 50, 10, 20, 3, true));
        l.add(new Preset("Exam 3 h", Prefs.MODE_COUNTDOWN, 180, 0, 25, 5, 15, 4, true));
        l.add(new Preset("Workout 45", Prefs.MODE_COUNTDOWN, 45, 0, 25, 5, 15, 4, true));
        l.add(new Preset("Cooking 15", Prefs.MODE_COUNTDOWN, 15, 0, 25, 5, 15, 4, true));
        l.add(new Preset("Meditation 10", Prefs.MODE_COUNTDOWN, 10, 0, 25, 5, 15, 4, true));
        return l;
    }

    static List<Preset> saved(SharedPreferences p) {
        List<Preset> l = new ArrayList<>();
        String raw = p.getString(Prefs.PRESETS, "");
        if (raw == null || raw.isEmpty()) return l;
        for (String line : raw.split("\n")) {
            String[] f = line.split("\\|", -1);
            if (f.length < 8) continue;
            try {
                l.add(new Preset(f[0], Integer.parseInt(f[1]), Integer.parseInt(f[2]),
                        Integer.parseInt(f[3]), Integer.parseInt(f[4]), Integer.parseInt(f[5]),
                        Integer.parseInt(f[6]), Integer.parseInt(f[7]), false));
            } catch (NumberFormatException ignored) {
            }
        }
        return l;
    }

    static void writeSaved(SharedPreferences p, List<Preset> list) {
        StringBuilder sb = new StringBuilder();
        for (Preset x : list) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(clean(x.name)).append('|').append(x.mode).append('|').append(x.cdMin)
                    .append('|').append(x.cdSec).append('|').append(x.work).append('|')
                    .append(x.shortBreak).append('|').append(x.longBreak).append('|')
                    .append(x.rounds);
        }
        p.edit().putString(Prefs.PRESETS, sb.toString()).apply();
    }

    static String clean(String s) {
        String t = s.replace('|', ' ').replace('\n', ' ').trim();
        if (t.length() > 18) t = t.substring(0, 18);
        return t.isEmpty() ? "My preset" : t;
    }

    static List<String> hidden(SharedPreferences p) {
        List<String> l = new ArrayList<>();
        String raw = p.getString(Prefs.PRESETS_HIDDEN, "");
        if (raw == null || raw.isEmpty()) return l;
        for (String s : raw.split("\n")) {
            if (!s.isEmpty()) l.add(s);
        }
        return l;
    }

    static void writeHidden(SharedPreferences p, List<String> names) {
        StringBuilder sb = new StringBuilder();
        for (String s : names) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(s);
        }
        p.edit().putString(Prefs.PRESETS_HIDDEN, sb.toString()).apply();
    }

    /** Apply a preset to the stored settings. */
    static void apply(SharedPreferences p, Preset x) {
        p.edit().putInt(Prefs.MODE, x.mode)
                .putInt(Prefs.CD_MIN, x.cdMin)
                .putInt(Prefs.CD_SEC, x.cdSec)
                .putInt(Prefs.POMO_WORK, x.work)
                .putInt(Prefs.POMO_SHORT, x.shortBreak)
                .putInt(Prefs.POMO_LONG, x.longBreak)
                .putInt(Prefs.POMO_ROUNDS, x.rounds)
                .apply();
    }

    /** True when the stored settings equal this preset (only the fields its mode uses). */
    static boolean matches(SharedPreferences p, Preset x) {
        if (Prefs.getInt(p, Prefs.MODE) != x.mode) return false;
        if (x.mode == Prefs.MODE_COUNTDOWN) {
            return Prefs.getInt(p, Prefs.CD_MIN) == x.cdMin && Prefs.getInt(p, Prefs.CD_SEC) == x.cdSec;
        }
        if (x.mode == Prefs.MODE_POMODORO) {
            return Prefs.getInt(p, Prefs.POMO_WORK) == x.work
                    && Prefs.getInt(p, Prefs.POMO_SHORT) == x.shortBreak
                    && Prefs.getInt(p, Prefs.POMO_LONG) == x.longBreak
                    && Prefs.getInt(p, Prefs.POMO_ROUNDS) == x.rounds;
        }
        return true;
    }

    static Preset current(SharedPreferences p, String name) {
        return new Preset(name, Prefs.getInt(p, Prefs.MODE), Prefs.getInt(p, Prefs.CD_MIN),
                Prefs.getInt(p, Prefs.CD_SEC), Prefs.getInt(p, Prefs.POMO_WORK),
                Prefs.getInt(p, Prefs.POMO_SHORT), Prefs.getInt(p, Prefs.POMO_LONG),
                Prefs.getInt(p, Prefs.POMO_ROUNDS), false);
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/SettingsActivity.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.CompoundButton;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/** Settings screen: theme, bubble behaviour, Pomodoro, alerts, help, privacy and about. */
public class SettingsActivity extends Activity {
    private static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT;
    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;
    static final String FEEDBACK_URL = "https://t.me/watchuhq";
    static final String UPDATE_URL = "https://github.com/Fury5645/floaty/releases";

    private SharedPreferences p;
    private Ui ui;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        p = Prefs.get(this);
        ui = new Ui(this, p);
        ui.styleWindow(this);

        FrameLayout frame = new FrameLayout(this);
        frame.setBackgroundColor(ui.surface);
        int maxW = Math.min(getResources().getDisplayMetrics().widthPixels, ui.dp(640));
        LinearLayout column = ui.vertical();
        frame.addView(column, new FrameLayout.LayoutParams(maxW, MATCH, Gravity.CENTER_HORIZONTAL));

        LinearLayout top = ui.horizontal();
        top.setPadding(ui.dp(8), ui.dp(6), ui.dp(8), ui.dp(6));
        ImageView back = ui.icon(R.drawable.ic_back, 24, ui.onSurface);
        back.setPadding(ui.dp(10), ui.dp(10), ui.dp(10), ui.dp(10));
        back.setContentDescription("Back");
        back.setOnClickListener(v -> finish());
        top.addView(back, new LinearLayout.LayoutParams(ui.dp(48), ui.dp(48)));
        top.addView(ui.medium("Settings", 22, ui.onSurface), ui.lp(WRAP, WRAP, 4, 0, 0, 0));
        column.addView(top, new LinearLayout.LayoutParams(MATCH, ui.dp(56)));

        ScrollView sv = new ScrollView(this);
        LinearLayout box = ui.vertical();
        box.setPadding(ui.dp(16), 0, ui.dp(16), ui.dp(24));
        sv.addView(box, new FrameLayout.LayoutParams(MATCH, WRAP));
        column.addView(sv, new LinearLayout.LayoutParams(MATCH, 0, 1f));

        // Appearance
        box.addView(ui.section("Appearance"), ui.lp(MATCH, WRAP, 0, 12, 0, 8));
        box.addView(ui.text("Theme", 16, ui.onSurface), ui.lp(MATCH, WRAP, 0, 0, 0, 8));
        box.addView(ui.segmented(new String[]{"Auto", "Light", "Dark", "AMOLED"},
                Prefs.getInt(p, Prefs.THEME), v -> {
                    p.edit().putInt(Prefs.THEME, v).apply();
                    recreate();
                }), ui.lp(MATCH, ui.dp(40), 0, 0, 0, 0));
        box.addView(ui.text("Auto follows your phone. AMOLED is pure black and saves battery on OLED screens.",
                13, ui.variant), ui.lp(MATCH, WRAP, 0, 6, 0, 4));

        // Bubble
        box.addView(ui.section("Bubble"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        toggle(box, "Lock position", "Stops accidental dragging", Prefs.LOCK);
        toggle(box, "Snap to edge", "Sticks to the nearest side of the screen", Prefs.SNAP);
        toggle(box, "Fade when idle", "Goes see-through after 5 seconds, solid on touch", Prefs.FADE);
        toggle(box, "Show seconds on timers", "Off shows minutes only, like 25m. Clock has its own switch.",
                Prefs.TIMER_SECS);

        // Pomodoro
        box.addView(ui.section("Pomodoro"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        toggle(box, "Auto-start next phase", "Off means it waits for your tap", Prefs.AUTONEXT);
        toggle(box, "\"Skip break?\" prompt", "Shown on the bubble when a break starts", Prefs.SKIPPROMPT);
        toggle(box, "Cycle counter", "Shows the cycle number on the bubble", Prefs.CYCLES);

        // Alerts
        box.addView(ui.section("Alerts"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        toggle(box, "Sound", "Quiet on silent mode and Do Not Disturb", Prefs.SOUND);
        toggle(box, "Vibration", null, Prefs.VIBRATE);
        toggle(box, "Loud alarm", "Rings even on silent or Do Not Disturb", Prefs.LOUD);

        // Advanced
        box.addView(ui.section("Advanced"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        toggle(box, "Pause when screen turns off",
                "Resumes when the screen turns on. Not used by Clock.", Prefs.SCREEN_PAUSE);
        toggle(box, "Pause when phone moves",
                "Pauses while the phone is picked up or moved, resumes after 5 still seconds.",
                Prefs.MOTION_PAUSE);

        // Help
        box.addView(ui.section("Help"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        box.addView(linkRow(R.drawable.ic_help, "Quick guide", "Replay the four-step tutorial",
                v -> startActivity(new Intent(this, GuideActivity.class))));
        box.addView(linkRow(R.drawable.ic_download, "Check for updates",
                "Opens the download page in your browser. You have version " + versionText() + ".",
                v -> openLink(UPDATE_URL)));
        box.addView(linkRow(R.drawable.ic_mail, "Send feedback",
                "Opens Telegram (WATCHU HQ). Nothing is sent automatically.",
                v -> openLink(FEEDBACK_URL)));

        // Privacy
        box.addView(ui.section("Privacy"), ui.lp(MATCH, WRAP, 0, 16, 0, 8));
        LinearLayout card = ui.horizontal();
        card.setGravity(Gravity.TOP);
        card.setBackground(ui.rounded(ui.greenC, 24));
        card.setPadding(ui.dp(16), ui.dp(16), ui.dp(16), ui.dp(16));
        card.addView(ui.icon(R.drawable.ic_shield, 28, ui.onGreenC), ui.lp(ui.dp(28), ui.dp(28), 0, 0, 14, 0));
        LinearLayout txt = ui.vertical();
        txt.addView(ui.medium("No data collected", 16, ui.onGreenC));
        txt.addView(ui.text("Watchu does not collect, store or share personal data. It has no internet "
                + "permission, so it cannot send anything anywhere. Your settings stay on this device.",
                14, ui.onGreenC), ui.lp(MATCH, WRAP, 0, 4, 0, 0));
        card.addView(txt, new LinearLayout.LayoutParams(0, WRAP, 1f));
        box.addView(card, ui.lp(MATCH, WRAP, 0, 0, 0, 0));

        // About
        box.addView(ui.section("About"), ui.lp(MATCH, WRAP, 0, 20, 0, 6));
        box.addView(ui.text("Watchu " + versionText(), 16, ui.onSurface));
        box.addView(ui.text("Free for life. No ads. No premium.", 14, ui.variant), ui.lp(MATCH, WRAP, 0, 2, 0, 0));

        setContentView(frame);
    }

    private String versionText() {
        try {
            PackageInfo pi = getPackageManager().getPackageInfo(getPackageName(), 0);
            return pi.versionName + " (build " + pi.versionCode + ")";
        } catch (Exception e) {
            return "";
        }
    }

    private void toggle(LinearLayout box, String title, String sub, final String key) {
        box.addView(ui.switchRow(title, sub, Prefs.getInt(p, key) == 1,
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton b, boolean on) {
                        p.edit().putInt(key, on ? 1 : 0).apply();
                        if (FloatingService.active) {
                            Intent i = new Intent(SettingsActivity.this, FloatingService.class);
                            i.setAction(FloatingService.ACTION_REFRESH);
                            startService(i);
                        }
                    }
                }));
    }

    private View linkRow(int iconRes, String title, String sub, View.OnClickListener l) {
        LinearLayout row = ui.horizontal();
        row.setMinimumHeight(ui.dp(64));
        row.addView(ui.icon(iconRes, 24, ui.variant), ui.lp(ui.dp(24), ui.dp(24), 0, 0, 16, 0));
        LinearLayout t = ui.vertical();
        t.addView(ui.text(title, 16, ui.onSurface));
        t.addView(ui.text(sub, 13, ui.variant));
        row.addView(t, new LinearLayout.LayoutParams(0, WRAP, 1f));
        row.setOnClickListener(l);
        return row;
    }

    private void openLink(String url) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception e) {
            Toast.makeText(this, "Could not open " + url, Toast.LENGTH_LONG).show();
        }
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/java/com/floaty/timer'
cat > 'app/src/main/java/com/floaty/timer/Ui.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.CompoundButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;

/** Colours for the app screens (light, dark, AMOLED) and small view-building helpers. */
final class Ui {
    static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT;
    static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;

    interface IntCb {
        void on(int value);
    }

    final Context ctx;
    final float density;
    final int themeId;
    final boolean dark;
    final int surface;
    final int container;
    final int high;
    final int onSurface;
    final int variant;
    final int outline;
    final int primary;
    final int onPrimary;
    final int secC;
    final int onSecC;
    final int line;
    final int greenC;
    final int onGreenC;
    private final Handler handler = new Handler(Looper.getMainLooper());

    /** Turns the saved choice (which may be Auto) into Light, Dark or AMOLED. */
    static int resolveTheme(Context c, SharedPreferences p) {
        int t = Prefs.getInt(p, Prefs.THEME);
        if (t != Prefs.THEME_AUTO) return t;
        int night = c.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
        return night == Configuration.UI_MODE_NIGHT_YES ? Prefs.THEME_DARK : Prefs.THEME_LIGHT;
    }

    Ui(Context c, SharedPreferences p) {
        ctx = c;
        density = c.getResources().getDisplayMetrics().density;
        themeId = resolveTheme(c, p);
        dark = themeId != Prefs.THEME_LIGHT;
        if (themeId == Prefs.THEME_LIGHT) {
            surface = 0xFFF8F9FF;
            container = 0xFFECEDF4;
            high = 0xFFE1E2E9;
            onSurface = 0xFF191C20;
            variant = 0xFF43474E;
            outline = 0xFF73777F;
            primary = 0xFF415F91;
            onPrimary = 0xFFFFFFFF;
            secC = 0xFFD6E3FF;
            onSecC = 0xFF001B3E;
            line = 0xFFD2D5DC;
            greenC = 0xFFC3F0D6;
            onGreenC = 0xFF00391F;
        } else {
            boolean black = themeId == Prefs.THEME_AMOLED;
            surface = black ? 0xFF000000 : 0xFF101319;
            container = black ? 0xFF0D0E11 : 0xFF1D2025;
            high = black ? 0xFF1A1C20 : 0xFF272A30;
            onSurface = 0xFFE1E2E9;
            variant = 0xFFC3C6CF;
            outline = 0xFF8D9199;
            primary = 0xFFA9C7FF;
            onPrimary = 0xFF08305F;
            secC = 0xFF3F4759;
            onSecC = 0xFFDBE2F9;
            line = black ? 0xFF22252A : 0xFF2B2F36;
            greenC = 0xFF0F3D27;
            onGreenC = 0xFFA0F4C0;
        }
    }

    /** Status bar and navigation bar colours that match the theme. */
    void styleWindow(android.app.Activity a) {
        android.view.Window w = a.getWindow();
        w.setStatusBarColor(surface);
        w.setNavigationBarColor(surface);
        int flags = 0;
        if (!dark) {
            flags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        }
        w.getDecorView().setSystemUiVisibility(flags);
    }

    int dp(float v) {
        return Math.round(v * density);
    }

    GradientDrawable rounded(int color, float radiusDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(dp(radiusDp));
        return g;
    }

    GradientDrawable outlined(int fill, int stroke, float radiusDp) {
        GradientDrawable g = rounded(fill, radiusDp);
        g.setStroke(dp(1), stroke);
        return g;
    }

    TextView text(String s, float sp, int color) {
        TextView t = new TextView(ctx);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        return t;
    }

    TextView medium(String s, float sp, int color) {
        TextView t = text(s, sp, color);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        return t;
    }

    LinearLayout.LayoutParams lp(int w, int h, float l, float t, float r, float b) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, h);
        p.setMargins(dp(l), dp(t), dp(r), dp(b));
        return p;
    }

    LinearLayout vertical() {
        LinearLayout l = new LinearLayout(ctx);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    LinearLayout horizontal() {
        LinearLayout l = new LinearLayout(ctx);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setGravity(Gravity.CENTER_VERTICAL);
        return l;
    }

    /** An icon from the drawable folder, painted in one colour. */
    ImageView icon(int resId, int sizeDp, int color) {
        ImageView v = new ImageView(ctx);
        v.setImageResource(resId);
        v.setImageTintList(ColorStateList.valueOf(color));
        v.setScaleType(ImageView.ScaleType.FIT_CENTER);
        v.setLayoutParams(new LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp)));
        return v;
    }

    /** Section heading in the accent colour. */
    TextView section(String s) {
        return medium(s, 14, primary);
    }

    /** A row of equal buttons where one is selected. */
    LinearLayout segmented(String[] labels, int selected, IntCb cb) {
        return segmented(labels, null, selected, cb);
    }

    LinearLayout segmented(final String[] labels, final Typeface[] faces, int selected, final IntCb cb) {
        final LinearLayout box = new LinearLayout(ctx);
        box.setOrientation(LinearLayout.HORIZONTAL);
        box.setBackground(outlined(0x00000000, outline, 20));
        box.setClipToOutline(true);
        final TextView[] items = new TextView[labels.length];
        for (int i = 0; i < labels.length; i++) {
            final int idx = i;
            TextView t = new TextView(ctx);
            t.setText(labels[i]);
            t.setTextSize(14);
            t.setGravity(Gravity.CENTER);
            t.setSingleLine(true);
            t.setPadding(dp(4), 0, dp(4), 0);
            if (faces != null && faces[i] != null) {
                t.setTypeface(faces[i]);
            } else {
                t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            }
            t.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    paintSegments(items, idx);
                    cb.on(idx);
                }
            });
            items[i] = t;
            if (i > 0) {
                View sep = new View(ctx);
                sep.setBackgroundColor(outline);
                box.addView(sep, new LinearLayout.LayoutParams(dp(1), MATCH));
            }
            box.addView(t, new LinearLayout.LayoutParams(0, MATCH, 1f));
        }
        paintSegments(items, selected);
        return box;
    }

    private void paintSegments(TextView[] items, int selected) {
        for (int i = 0; i < items.length; i++) {
            boolean on = i == selected;
            items[i].setBackground(new ColorDrawable(on ? secC : 0x00000000));
            items[i].setTextColor(on ? onSecC : onSurface);
        }
    }

    /** A small selectable chip. */
    TextView chip(String label, boolean selected, boolean accentOutline) {
        TextView t = medium(label, 14, selected ? onSecC : onSurface);
        t.setGravity(Gravity.CENTER);
        t.setSingleLine(true);
        t.setPadding(dp(12), 0, dp(12), 0);
        if (selected) {
            t.setBackground(rounded(secC, 8));
        } else {
            t.setBackground(outlined(0x00000000, accentOutline ? primary : outline, 8));
        }
        t.setMinHeight(dp(32));
        t.setMinimumHeight(dp(32));
        return t;
    }

    /** Text button without a background, in the accent colour. */
    LinearLayout textButton(String label, int iconRes, View.OnClickListener l) {
        LinearLayout b = horizontal();
        b.setPadding(dp(10), 0, dp(10), 0);
        b.setMinimumHeight(dp(36));
        if (iconRes != 0) b.addView(icon(iconRes, 16, primary), lp(dp(16), dp(16), 0, 0, 5, 0));
        b.addView(medium(label, 13, primary));
        b.setOnClickListener(l);
        return b;
    }

    Switch makeSwitch(boolean on, CompoundButton.OnCheckedChangeListener l) {
        Switch s = new Switch(ctx);
        s.setChecked(on);
        int[][] states = new int[][]{new int[]{android.R.attr.state_checked}, new int[]{}};
        s.setThumbTintList(new ColorStateList(states, new int[]{onPrimary, outline}));
        s.setTrackTintList(new ColorStateList(states, new int[]{primary, high}));
        s.setOnCheckedChangeListener(l);
        return s;
    }

    /** A row with a title, optional smaller line, and a switch on the right. */
    LinearLayout switchRow(String title, String sub, boolean on, CompoundButton.OnCheckedChangeListener l) {
        LinearLayout row = horizontal();
        row.setMinimumHeight(dp(sub == null ? 52 : 64));
        LinearLayout labels = vertical();
        labels.addView(text(title, 16, onSurface));
        if (sub != null) labels.addView(text(sub, 13, variant));
        row.addView(labels, new LinearLayout.LayoutParams(0, WRAP, 1f));
        row.addView(makeSwitch(on, l), lp(WRAP, WRAP, 12, 0, 0, 0));
        return row;
    }

    /** Round plus/minus button. Tap changes by one; hold repeats. */
    TextView stepButton(String sign, final Runnable action) {
        final TextView b = medium(sign, 20, onSurface);
        b.setGravity(Gravity.CENTER);
        b.setBackground(rounded(high, 18));
        final Runnable[] repeat = new Runnable[1];
        repeat[0] = new Runnable() {
            @Override
            public void run() {
                action.run();
                handler.postDelayed(repeat[0], 110L);
            }
        };
        b.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent e) {
                int a = e.getActionMasked();
                if (a == MotionEvent.ACTION_DOWN) {
                    action.run();
                    handler.postDelayed(repeat[0], 450L);
                    return true;
                }
                if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL) {
                    handler.removeCallbacks(repeat[0]);
                    return true;
                }
                return true;
            }
        });
        return b;
    }

    // ---- colour rule: text and ring must not be the same as (or too close to) the background

    static double lum(int c) {
        double r = chan(((c >> 16) & 0xFF) / 255.0);
        double g = chan(((c >> 8) & 0xFF) / 255.0);
        double b = chan((c & 0xFF) / 255.0);
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    private static double chan(double v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    static boolean tooClose(int a, int b) {
        double l1 = lum(a);
        double l2 = lum(b);
        double hi = Math.max(l1, l2);
        double lo = Math.min(l1, l2);
        return (hi + 0.05) / (lo + 0.05) < 1.8;
    }
}
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_back.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M19,12 H5 M12,19 l-7,-7 7,-7"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_check.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M5,12 l5,5 9,-10"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_download.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M12,3 v12 M7,10 l5,5 5,-5 M5,21 h14"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_edit.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M4,20 h4 L19,9 l-4,-4 L4,16 z"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
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
        android:pathData="M38.879999999999995,59.04 a20.16,20.16 0 1,0 40.32,0 a20.16,20.16 0 1,0 -40.32,0"
        android:strokeAlpha="0.28"
        android:strokeColor="#08305F"
        android:strokeWidth="5.88" />
    <path
        android:fillColor="#00000000"
        android:pathData="M33.0,53.16 a20.16,20.16 0 1,0 40.32,0 a20.16,20.16 0 1,0 -40.32,0"
        android:strokeColor="#08305F"
        android:strokeWidth="5.88" />
    <path
        android:fillColor="#00000000"
        android:pathData="M53.16,53.16 L53.16,42.24 M53.16,53.16 L60.72,57.36"
        android:strokeColor="#08305F"
        android:strokeLineCap="round"
        android:strokeWidth="3.36" />
    <path
        android:fillColor="#08305F"
        android:pathData="M63.66,38.88 a3.78,3.78 0 1,0 7.56,0 a3.78,3.78 0 1,0 -7.56,0" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_gear.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M9,12 a3,3 0 1,0 6,0 a3,3 0 1,0 -6,0 M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_help.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M3,12 a9,9 0 1,0 18,0 a9,9 0 1,0 -18,0 M9.5,9.5 a2.5,2.5 0 1 1 3.5,2.3 c-.6,.3 -1,.9 -1,1.6 M12,17 h.01"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_logo.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="36dp"
    android:height="36dp"
    android:viewportWidth="36"
    android:viewportHeight="36">
    <path
        android:fillColor="#A9C7FF"
        android:pathData="M11,0 h14 a11,11 0 0 1 11,11 v14 a11,11 0 0 1 -11,11 h-14 a11,11 0 0 1 -11,-11 v-14 a11,11 0 0 1 11,-11 z" />
    <path
        android:fillColor="#00000000"
        android:pathData="M12.0,20.5 a8.5,8.5 0 1,0 17.0,0 a8.5,8.5 0 1,0 -17.0,0"
        android:strokeAlpha="0.28"
        android:strokeColor="#08305F"
        android:strokeWidth="3" />
    <path
        android:fillColor="#00000000"
        android:pathData="M8.5,17 a8.5,8.5 0 1,0 17.0,0 a8.5,8.5 0 1,0 -17.0,0"
        android:strokeColor="#08305F"
        android:strokeWidth="3" />
    <path
        android:fillColor="#00000000"
        android:pathData="M17,17 L17,12 M17,17 L20.5,19"
        android:strokeColor="#08305F"
        android:strokeLineCap="round"
        android:strokeWidth="2" />
    <path
        android:fillColor="#08305F"
        android:pathData="M21.5,10.5 a2,2 0 1,0 4,0 a2,2 0 1,0 -4,0" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_mail.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M6,5 h12 a3,3 0 0 1 3,3 v8 a3,3 0 0 1 -3,3 h-12 a3,3 0 0 1 -3,-3 v-8 a3,3 0 0 1 3,-3 z M3,8 l9,6 9,-6"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_nav_stats.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M5,21 V11 M12,21 V4 M19,21 v-7"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_nav_style.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M12,3 a9,9 0 1 0 0,18 c1.2,0 2,-.8 2,-1.8 0,-.5 -.2,-.9 -.5,-1.3 -.3,-.4 -.5,-.8 -.5,-1.3 0,-1 .8,-1.6 1.8,-1.6 H17 a4,4 0 0 0 4,-4 c0,-4.4 -4,-8 -9,-8 z M6.5,11 a1,1 0 1,0 2,0 a1,1 0 1,0 -2,0 M9.5,7 a1,1 0 1,0 2,0 a1,1 0 1,0 -2,0 M14.5,7.5 a1,1 0 1,0 2,0 a1,1 0 1,0 -2,0"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_nav_timer.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M4,13 a8,8 0 1,0 16,0 a8,8 0 1,0 -16,0 M12,9 v4 l2.5,2 M9,2 h6"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_play.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M8,5 v14 l11,-7 z" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_plus.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M12,5 v14 M5,12 h14"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_shape_circle.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M4,12 a8,8 0 1,0 16,0 a8,8 0 1,0 -16,0"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_shape_pill.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M7,7 h10 a5,5 0 0 1 5,5 v0 a5,5 0 0 1 -5,5 h-10 a5,5 0 0 1 -5,-5 v0 a5,5 0 0 1 5,-5 z"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_shape_squircle.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M10,4 h4 a6,6 0 0 1 6,6 v4 a6,6 0 0 1 -6,6 h-4 a6,6 0 0 1 -6,-6 v-4 a6,6 0 0 1 6,-6 z"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_shield.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M12,3 l8,3 v6 c0,4.5 -3.2,8 -8,9 -4.8,-1 -8,-4.5 -8,-9 V6 z M8.5,12 l2.5,2.5 4.5,-5"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/ic_stop.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M7,7 h10 v10 H7 z" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/wm_main.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="119.6dp"
    android:height="28dp"
    android:viewportWidth="3416"
    android:viewportHeight="800">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M1028 58 845 760H638L526 298L410 760H203L25 58H208L309 569L434 58H622L742 569L844 58ZM1326 194Q1385 194 1429.5 218Q1474 242 1498 281V202H1669V760H1498V681Q1473 720 1428.5 744Q1384 768 1325 768Q1257 768 1201 732.5Q1145 697 1112.5 631.5Q1080 566 1080 480Q1080 394 1112.5 329Q1145 264 1201 229Q1257 194 1326 194ZM1376 343Q1325 343 1289.5 379.5Q1254 416 1254 480Q1254 544 1289.5 581.5Q1325 619 1376 619Q1427 619 1462.5 582Q1498 545 1498 481Q1498 417 1462.5 380Q1427 343 1376 343ZM2104 615V760H2017Q1924 760 1872 714.5Q1820 669 1820 566V344H1752V202H1820V66H1991V202H2103V344H1991V568Q1991 593 2003 604Q2015 615 2043 615ZM2445 194Q2550 194 2620.5 249Q2691 304 2713 404H2531Q2508 340 2442 340Q2395 340 2367 376.5Q2339 413 2339 481Q2339 549 2367 585.5Q2395 622 2442 622Q2508 622 2531 558H2713Q2691 656 2620 712Q2549 768 2445 768Q2363 768 2299.5 733Q2236 698 2200.5 633Q2165 568 2165 481Q2165 394 2200.5 329Q2236 264 2299.5 229Q2363 194 2445 194ZM3359 434V760H3189V457Q3189 401 3160 370Q3131 339 3082 339Q3033 339 3004 370Q2975 401 2975 457V760H2804V20H2975V277Q3001 240 3046 218Q3091 196 3147 196Q3243 196 3301 259.5Q3359 323 3359 434Z" />
</vector>
FLOATY_EOF
mkdir -p 'app/src/main/res/drawable'
cat > 'app/src/main/res/drawable/wm_u.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="23.6dp"
    android:height="28dp"
    android:viewportWidth="674"
    android:viewportHeight="800">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M613 202V760H442V684Q416 721 371.5 743.5Q327 766 273 766Q209 766 160 737.5Q111 709 84 655Q57 601 57 528V202H227V505Q227 561 256 592Q285 623 334 623Q384 623 413 592Q442 561 442 505V202Z" />
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
    <string name="app_name">Watchu</string>
    <color name="ic_bg">#A9C7FF</color>
</resources>
FLOATY_EOF
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
rootProject.name = "Watchu"
include ':app'
FLOATY_EOF
