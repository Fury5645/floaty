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
        versionName '1.15'
    }

    // Uses your private key when the secrets are set in GitHub; otherwise the default debug key.
    def ksPass = System.getenv('KEYSTORE_PASSWORD')
    if (ksPass && file('watchu.keystore').exists()) {
        signingConfigs {
            debug {
                storeFile file('watchu.keystore')
                storePassword ksPass
                keyAlias 'watchu'
                keyPassword ksPass
            }
        }
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
            <intent-filter>
                <action android:name="android.service.quicksettings.action.QS_TILE_PREFERENCES" />
            </intent-filter>
        </activity>

        <activity
            android:name=".SettingsActivity"
            android:exported="false" />

        <activity
            android:name=".DeskActivity"
            android:configChanges="orientation|screenSize|screenLayout|keyboardHidden"
            android:exported="false" />

        <activity
            android:name=".QuickStartActivity"
            android:exported="false"
            android:excludeFromRecents="true"
            android:taskAffinity=""
            android:theme="@android:style/Theme.NoDisplay" />

        <activity
            android:name=".GuideActivity"
            android:exported="false" />

        <receiver
            android:name=".WatchuWidget"
            android:exported="true"
            android:label="@string/app_name">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/widget_info" />
        </receiver>

        <service
            android:name=".QuickTileService"
            android:exported="true"
            android:icon="@drawable/ic_tile"
            android:label="@string/app_name"
            android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
            <intent-filter>
                <action android:name="android.service.quicksettings.action.QS_TILE" />
            </intent-filter>
        </service>

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
    boolean paused = false;

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

    float skipAlpha = 0f;

    void setSkip(float a) {
        skipAlpha = a;
    }

    @Override
    protected void onDraw(Canvas c) {
        drawAll(c);
        if (skipAlpha > 0.01f) drawSkip(c);
    }

    /** Small round "skip break" badge on the right side of the bubble. */
    private void drawSkip(Canvas c) {
        float w = getWidth();
        float h = getHeight();
        float rad = Math.min(w, h) * 0.14f;
        float cx = w - rad - density * 3f;
        float cy = h / 2f;
        int a = Math.round(255f * Math.min(1f, skipAlpha));
        int col = ringColor != 0 ? ringColor : accent;
        fill.setShader(null);
        fill.setStyle(Paint.Style.FILL);
        fill.setColor(withAlpha(col, a));
        c.drawCircle(cx, cy, rad, fill);
        fill.setColor(withAlpha(bg, a));
        android.graphics.Path tri = new android.graphics.Path();
        tri.moveTo(cx - rad * 0.40f, cy - rad * 0.42f);
        tri.lineTo(cx - rad * 0.40f, cy + rad * 0.42f);
        tri.lineTo(cx + rad * 0.22f, cy);
        tri.close();
        c.drawPath(tri, fill);
        c.drawRoundRect(cx + rad * 0.30f, cy - rad * 0.42f, cx + rad * 0.46f, cy + rad * 0.42f,
                rad * 0.06f, rad * 0.06f, fill);
        postInvalidateDelayed(120L);
    }

    void setPaused(boolean v) {
        paused = v;
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

    int aface = 0;
    int akind = 0;

    /**
     * Draw an analog dial instead of digits. face: 0 Classic, 1 Minimal, 2 Wedge, 3 Ring.
     * kind: 0 clock (hands), 1 countdown (prog = time left), 2 stopwatch (prog = part of the minute).
     */
    void setDial(int face, int kind, float prog, float hourDeg, float minDeg, float secDeg,
                 boolean secHand, String t, String l, int rc, boolean hl) {
        analogFace = face + 1;
        aface = face;
        akind = kind;
        angHour = hourDeg;
        angMin = minDeg;
        angSec = secDeg;
        showSecHand = secHand;
        text = t;
        label = l;
        progress = prog;
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

    private void drawAll(Canvas c) {
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
        boolean hasLabel = label != null;
        float breathe = 1f;
        if (paused) breathe = 0.55f + 0.45f * (0.5f + 0.5f * (float) Math.sin((SystemClock.uptimeMillis() % 3200L) / 3200f * 2.0 * Math.PI - 1.5708f));

        float base = pill ? (hasLabel ? h * 0.36f : h * 0.42f) : h * 0.27f;
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
                arc.setColor(paused ? withAlpha(accentC, Math.round(255f * breathe)) : accentC);
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
                    arc.setColor(paused ? withAlpha(accentC, Math.round(255f * breathe)) : accentC);
                    c.drawPath(seg, arc);
                }
            }
        }

        float cyMain = hasLabel ? (pill ? h * 0.43f : h * 0.45f) : h * 0.5f;
        float baseline = cyMain + ms * 0.36f;
        if (font == Prefs.FONT_MONO) {
            drawSeven(c, text, w / 2f, cyMain, ms * 0.92f, w * (ringOn ? 0.66f : 0.78f), ink);
        } else {
            c.drawText(text, w / 2f, baseline, mainText);
        }

        if (hasLabel) {
            float ls = ms * (pill ? 0.34f : 0.36f);
            labelText.setTextSize(ls);
            float lw = labelText.measureText(label);
            float iconW = paused ? ls * 1.3f : 0f;
            float lavail = w * (circle ? 0.62f : 0.80f) - iconW;
            if (lw > lavail) {
                ls = ls * lavail / lw;
                labelText.setTextSize(ls);
                lw = labelText.measureText(label);
                iconW = paused ? ls * 1.3f : 0f;
            }
            labelText.setColor(accentC);
            float ly = baseline + ls * 1.45f;
            float lx = w / 2f + iconW / 2f;
            c.drawText(label, lx, ly, labelText);
            if (paused) {
                float bh = ls * 0.95f;
                float bw = ls * 0.28f;
                float ix = lx - lw / 2f - ls * 0.55f;
                float iy = ly - bh * 0.95f;
                fill.setColor(withAlpha(accentC, Math.round(255f * breathe)));
                c.drawRoundRect(ix - bw * 1.3f, iy, ix - bw * 0.3f, iy + bh, bw * 0.3f, bw * 0.3f, fill);
                c.drawRoundRect(ix + bw * 0.3f, iy, ix + bw * 1.3f, iy + bh, bw * 0.3f, bw * 0.3f, fill);
            }
        }
        if (paused) postInvalidateDelayed(50L);
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

    // ---------------------------------------------------------------- seven-segment digits

    private static final int[] SEG = {63, 6, 91, 79, 102, 109, 125, 7, 127, 111};

    private void bar(Canvas c, float l, float t, float r, float b, float rad) {
        c.drawRoundRect(l, t, r, b, rad, rad, fill);
    }

    private void drawSeven(Canvas c, String s, float cx, float cy, float hgt, float availW, int ink) {
        float total = 0f;
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch >= '0' && ch <= '9') total += hgt * 0.54f + hgt * 0.14f;
            else if (ch == ':') total += hgt * 0.26f + hgt * 0.10f;
            else total += hgt * 0.30f;
        }
        if (total > availW) {
            float k = availW / total;
            hgt *= k;
            total *= k;
        }
        float dw = hgt * 0.54f;
        float t = hgt * 0.13f;
        float rad = t / 2f;
        float x = cx - (total - hgt * 0.14f) / 2f;
        float y = cy - hgt / 2f;
        float mid = hgt / 2f;
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch >= '0' && ch <= '9') {
                int mask = SEG[ch - '0'];
                for (int k = 0; k < 7; k++) {
                    boolean on = (mask & (1 << k)) != 0;
                    fill.setColor(on ? ink : withAlpha(ink, 30));
                    float l, tp, r, b;
                    if (k == 0) { l = x + t * 0.5f; tp = y; r = x + dw - t * 0.5f; b = y + t; }
                    else if (k == 1) { l = x + dw - t; tp = y + t * 0.6f; r = x + dw; b = y + mid - t * 0.35f; }
                    else if (k == 2) { l = x + dw - t; tp = y + mid + t * 0.35f; r = x + dw; b = y + hgt - t * 0.6f; }
                    else if (k == 3) { l = x + t * 0.5f; tp = y + hgt - t; r = x + dw - t * 0.5f; b = y + hgt; }
                    else if (k == 4) { l = x; tp = y + mid + t * 0.35f; r = x + t; b = y + hgt - t * 0.6f; }
                    else if (k == 5) { l = x; tp = y + t * 0.6f; r = x + t; b = y + mid - t * 0.35f; }
                    else { l = x + t * 0.5f; tp = y + mid - t / 2f; r = x + dw - t * 0.5f; b = y + mid + t / 2f; }
                    bar(c, l, tp, r, b, rad);
                }
                x += dw + hgt * 0.14f;
            } else if (ch == ':') {
                fill.setColor(ink);
                float d = t * 0.9f;
                float mx = x + hgt * 0.13f;
                c.drawCircle(mx, y + hgt * 0.30f, d / 2f, fill);
                c.drawCircle(mx, y + hgt * 0.70f, d / 2f, fill);
                x += hgt * 0.26f + hgt * 0.10f;
            } else {
                x += hgt * 0.30f;
            }
        }
    }

    // ---------------------------------------------------------------- analog dials

    private void drawAnalog(Canvas c, float w, float h, int ink, int accentC) {
        float cx = w / 2f;
        float cy = h / 2f;
        float rad = Math.min(w, h) / 2f;
        float dial = rad * 0.86f;
        float breathe = 1f;
        if (paused) {
            breathe = 0.55f + 0.45f * (0.5f + 0.5f * (float) Math.sin(
                    (SystemClock.uptimeMillis() % 3200L) / 3200f * 2.0 * Math.PI - 1.5708f));
        }
        int acc = paused ? withAlpha(accentC, Math.round(255f * breathe)) : accentC;
        boolean clock = akind == 0;
        float frac = clock ? (showSecHand ? angSec : angMin) / 360f : clamp01(progress);
        float ang = frac * 360f;
        arc.setStyle(Paint.Style.STROKE);
        arc.setStrokeCap(Paint.Cap.ROUND);

        if (aface == 0) {
            for (int i = 0; i < 12; i++) {
                boolean major = i % 3 == 0;
                float len = dial * (major ? 0.16f : 0.09f);
                double a = Math.toRadians(i * 30.0);
                float dx = (float) Math.sin(a);
                float dy = (float) -Math.cos(a);
                arc.setStrokeWidth(Math.max(density * 1.2f, dial * (major ? 0.05f : 0.03f)));
                arc.setColor(withAlpha(ink, major ? 255 : 150));
                c.drawLine(cx + dx * dial, cy + dy * dial, cx + dx * (dial - len), cy + dy * (dial - len), arc);
            }
            if (clock) {
                mainText.setColor(ink);
                mainText.setTextSize(dial * 0.26f);
                float off = mainText.getTextSize() * 0.36f;
                float nr = dial * 0.68f;
                c.drawText("12", cx, cy - nr + off, mainText);
                c.drawText("3", cx + nr, cy + off, mainText);
                c.drawText("6", cx, cy + nr + off, mainText);
                c.drawText("9", cx - nr, cy + off, mainText);
            }
        } else if (aface == 1) {
            for (int i = 0; i < 4; i++) {
                double a = Math.toRadians(i * 90.0);
                fill.setColor(withAlpha(ink, 170));
                c.drawCircle(cx + (float) Math.sin(a) * dial * 0.92f, cy - (float) Math.cos(a) * dial * 0.92f,
                        Math.max(density, dial * 0.03f), fill);
            }
        } else if (aface == 2) {
            r2.set(cx - dial, cy - dial, cx + dial, cy + dial);
            fill.setColor(withAlpha(ink, 28));
            c.drawCircle(cx, cy, dial, fill);
            fill.setColor(withAlpha(acc, clock ? 120 : 230));
            if (frac > 0.002f) c.drawArc(r2, -90f, ang, true, fill);
            if (!clock) {
                fill.setColor(withAlpha(bg, Math.round(255f * opacityPct / 100f)));
                c.drawCircle(cx, cy, dial * 0.64f, fill);
            }
        } else {
            float sw = dial * 0.13f;
            float rr = dial - sw / 2f;
            r2.set(cx - rr, cy - rr, cx + rr, cy + rr);
            arc.setStrokeWidth(sw);
            arc.setColor(withAlpha(ink, 40));
            c.drawOval(r2, arc);
            if (frac > 0.002f) {
                arc.setColor(acc);
                c.drawArc(r2, -90f, ang, false, arc);
            }
            double a = Math.toRadians(ang);
            fill.setColor(acc);
            c.drawCircle(cx + (float) Math.sin(a) * rr, cy - (float) Math.cos(a) * rr, sw * 0.85f, fill);
        }

        if (clock) {
            float hl = aface == 3 ? 0.46f : 0.50f;
            float ml = aface == 3 ? 0.66f : 0.74f;
            float tw = aface == 1 ? 0.6f : 1f;
            hand(c, cx, cy, angHour, dial * hl, dial * 0.06f, Math.max(density * 2f, dial * 0.08f * tw), ink);
            hand(c, cx, cy, angMin, dial * ml, dial * 0.06f, Math.max(density * 1.6f, dial * 0.055f * tw), ink);
            if (showSecHand && aface != 3 && aface != 2) {
                hand(c, cx, cy, angSec, dial * 0.80f, dial * 0.14f, Math.max(density, dial * 0.025f), acc);
            }
            fill.setColor(acc);
            c.drawCircle(cx, cy, Math.max(density * 2.5f, dial * 0.06f), fill);
        } else {
            if (aface == 0 || aface == 1) {
                float tw = aface == 1 ? 0.6f : 1f;
                hand(c, cx, cy, ang, dial * 0.78f, dial * 0.10f, Math.max(density * 1.6f, dial * 0.06f * tw), acc);
                fill.setColor(acc);
                c.drawCircle(cx, cy, Math.max(density * 2.5f, dial * 0.06f), fill);
            }
            if (text != null) {
                boolean low = aface == 0 || aface == 1;
                mainText.setColor(ink);
                float ts = dial * (low ? 0.27f : 0.34f);
                mainText.setTextSize(ts);
                float tw2 = mainText.measureText(text);
                float maxw = dial * (low ? 1.2f : 1.15f);
                if (tw2 > maxw) {
                    ts = ts * maxw / tw2;
                    mainText.setTextSize(ts);
                }
                float ty = low ? cy + dial * 0.50f + ts * 0.36f : cy + ts * 0.36f - (label != null ? dial * 0.05f : 0f);
                c.drawText(text, cx, ty, mainText);
                if (label != null) {
                    float ls = dial * 0.13f;
                    labelText.setTextSize(ls);
                    labelText.setColor(acc);
                    float ly = low ? cy + dial * 0.74f : cy + dial * 0.40f;
                    c.drawText(label, cx, ly, labelText);
                }
            }
        }
        arc.setStrokeCap(Paint.Cap.ROUND);
        if (paused) postInvalidateDelayed(50L);
    }
}
FLOATY_EOF
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
    static final String ACTION_DESK_ON = "com.watchu.timer.DESK_ON";
    static final String ACTION_DESK_OFF = "com.watchu.timer.DESK_OFF";
    static final String ACTION_TOGGLE = "com.watchu.timer.TOGGLE";
    static final String ACTION_RESET = "com.watchu.timer.RESET";
    static final String ACTION_SKIP = "com.watchu.timer.SKIP";
    static final String ACTION_QUICK = "com.watchu.timer.QUICK";
    static volatile boolean dBreak = false;

    // What the bubble shows right now, published for the Desk mode screen.
    static volatile boolean deskOpen = false;
    static volatile String dText = "";
    static volatile String dLabel = null;
    static volatile float dProg = -1f;
    static volatile float dHour = 0f;
    static volatile float dMin = 0f;
    static volatile float dSecA = 0f;
    static volatile int dRing = 0;
    static volatile int dFace = -1;
    static volatile int dKind = 0;
    static volatile boolean dHl = false;
    static volatile boolean dPaused = false;
    static volatile boolean dSecHand = false;
    static volatile boolean dClock = false;

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
    /** Skip-break badge on the bubble is shown until this time. */
    private long skipUntil;
    /** A second long press before this time resets the whole Pomodoro. */
    private long resetArmUntil;
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

    private long lastStatE = 0L;
    private long statAcc = 0L;

    private void trackStats() {
        long ne = SystemClock.elapsedRealtime();
        if (lastStatE != 0L) {
            long d = ne - lastStatE;
            boolean counts = timerRunning && mode != Prefs.MODE_CLOCK && !alarming
                    && !(mode == Prefs.MODE_POMODORO && phase != PHASE_WORK);
            if (counts && d > 0L && d <= 5000L) statAcc += d;
        }
        lastStatE = ne;
        if (statAcc >= 10000L) flushStats();
    }

    private void flushStats() {
        int sec = (int) (statAcc / 1000L);
        if (sec > 0) {
            Stats.addSeconds(prefs, sec);
            statAcc -= sec * 1000L;
        }
    }

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            update();
            trackStats();
            refreshNotification();
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
        } else if (ACTION_DESK_ON.equals(a)) {
            deskOpen = true;
            if (bubble != null) bubble.setVisibility(View.GONE);
        } else if (ACTION_DESK_OFF.equals(a)) {
            deskOpen = false;
            if (bubble != null) bubble.setVisibility(View.VISIBLE);
        } else if (ACTION_TOGGLE.equals(a)) {
            onTap();
        } else if (ACTION_RESET.equals(a)) {
            onLongPress();
        } else if (ACTION_SKIP.equals(a)) {
            skipBreak();
        } else if (ACTION_QUICK.equals(a)) {
            applyStyle();
            loadConfig();
            syncMotion();
            stopAlarm();
            resetState();
            if (mode != Prefs.MODE_CLOCK && !timerRunning) toggleRun();
            update();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(tick);
        flushStats();
        WatchuWidget.refresh(this);
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
        deskOpen = false;
        active = false;
        super.onDestroy();
    }

    // ------------------------------------------------------------ foreground notification

    private String notifSig = "";
    private long notifCheckAt = 0L;
    private int todayBase = 0;
    private int examCache = -1;

    private PendingIntent actionPi(int code, String action) {
        Intent i = new Intent(this, FloatingService.class);
        i.setAction(action);
        return PendingIntent.getService(this, code, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private Notification buildNotification() {
        long now = SystemClock.elapsedRealtime();
        PendingIntent openPi = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        boolean clock = mode == Prefs.MODE_CLOCK;
        String title;
        if (alarming) {
            title = "Time's up";
        } else if (mode == Prefs.MODE_POMODORO) {
            title = phase == PHASE_WORK ? "Focus " + round + "/" + roundsBeforeLong
                    : (phase == PHASE_SHORT ? "Break" : "Long break");
        } else if (mode == Prefs.MODE_STOPWATCH) {
            title = "Stopwatch";
        } else if (clock) {
            title = "Clock";
        } else {
            title = "Timer";
        }
        boolean live = !clock && timerRunning && !alarming;
        if (!clock && !timerRunning && !alarming) title += " \u00B7 paused";
        int goal = Prefs.getInt(prefs, Prefs.GOAL_MIN) * 60;
        int today = todayBase + (int) (statAcc / 1000L);
        String line = "Today " + Stats.dur(today) + " of " + Stats.dur(goal);
        String exam = examCache == 0 ? "Exam day"
                : (examCache > 0 ? "Exam in " + examCache + (examCache == 1 ? " day" : " days") : null);
        Notification.Builder nb = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(title)
                .setContentText(exam == null ? line : line + "  \u00B7  " + exam)
                .setStyle(new Notification.BigTextStyle().bigText(exam == null ? line : line + "\n" + exam))
                .setContentIntent(openPi)
                .setOngoing(true)
                .setOnlyAlertOnce(true);
        if (goal > 0) nb.setProgress(goal, Math.min(today, goal), false);
        if (live) {
            long el = accumulatedMs + (now - baseElapsed);
            if (mode == Prefs.MODE_STOPWATCH) {
                nb.setShowWhen(true).setUsesChronometer(true).setWhen(System.currentTimeMillis() - el);
            } else {
                long rem = Math.max(0L, totalMs - el);
                nb.setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
                        .setWhen(System.currentTimeMillis() + rem);
            }
        } else {
            nb.setShowWhen(false);
        }
        if (mode == Prefs.MODE_POMODORO && phase != PHASE_WORK) {
            nb.addAction(new Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_media_next), "Skip break",
                    actionPi(3, ACTION_SKIP)).build());
        }
        if (!clock) {
            nb.addAction(new Notification.Action.Builder(
                    Icon.createWithResource(this, timerRunning ? android.R.drawable.ic_media_pause
                            : android.R.drawable.ic_media_play),
                    timerRunning ? "Pause" : "Resume", actionPi(2, ACTION_TOGGLE)).build());
        }
        nb.addAction(new Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                "Stop", actionPi(1, ACTION_STOP)).build());
        return nb.build();
    }

    /** Re-posts the notification when something it shows has changed. */
    private void refreshNotification() {
        long now = SystemClock.elapsedRealtime();
        if (notifCheckAt == 0L || now - notifCheckAt >= 20000L) {
            notifCheckAt = now;
            todayBase = Stats.secs(Stats.load(prefs), Stats.cal(0));
            examCache = Stats.examDays(prefs);
        }
        int today = todayBase + (int) (statAcc / 1000L);
        String sig = mode + "|" + phase + "|" + round + "|" + timerRunning + "|" + alarming + "|"
                + (today / 60) + "|" + Prefs.getInt(prefs, Prefs.GOAL_MIN) + "|" + examCache;
        if (sig.equals(notifSig)) return;
        notifSig = sig;
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        nm.notify(NOTIF_ID, buildNotification());
    }

    private void startAsForeground() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Watchu floating timer",
                NotificationManager.IMPORTANCE_LOW));
        Notification n = buildNotification();
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
                        onTapAt(e.getX());
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
            if (Prefs.getInt(prefs, Prefs.LIMIT_BREAKS) == 1) minutes = Math.min(minutes, Prefs.maxShort(prefs));
        } else {
            minutes = Prefs.getInt(prefs, Prefs.POMO_LONG);
            if (Prefs.getInt(prefs, Prefs.LIMIT_BREAKS) == 1) minutes = Math.min(minutes, Prefs.maxLong(prefs));
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
        skipUntil = 0L;
        resetArmUntil = 0L;
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
        resetArmUntil = 0L;
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

    private void onTapAt(float x) {
        if (!alarming && mode == Prefs.MODE_POMODORO && phase != PHASE_WORK && bubble != null
                && SystemClock.elapsedRealtime() < skipUntil && x >= bubble.getWidth() * 0.60f) {
            skipBreak();
            return;
        }
        onTap();
    }

    private void skipBreak() {
        if (mode != Prefs.MODE_POMODORO || phase == PHASE_WORK) return;
        stopAlarm();
        nextPhase(true);
        timerRunning = true;
        waitingStart = false;
        update();
    }

    private void onLongPress() {
        if (mode == Prefs.MODE_CLOCK) return;
        stopAlarm();
        long now = SystemClock.elapsedRealtime();
        boolean fullReset = true;
        if (mode == Prefs.MODE_POMODORO) {
            if (now < resetArmUntil) {
                resetState();
            } else {
                // First press: only restart the step you are in (round and cycle stay).
                screenPaused = false;
                motionPaused = false;
                accumulatedMs = 0L;
                timerRunning = false;
                alarming = false;
                waitingStart = false;
                promptUntil = 0L;
                totalMs = phaseMs(phase);
                resetArmUntil = now + 5000L;
                fullReset = false;
            }
        } else {
            resetState();
        }
        update();
        if (vibrator != null && vibrator.hasVibrator()) {
            try {
                if (fullReset) {
                    vibrator.vibrate(VibrationEffect.createWaveform(new long[]{0, 40, 70, 40}, -1));
                } else {
                    vibrator.vibrate(VibrationEffect.createOneShot(40L, VibrationEffect.DEFAULT_AMPLITUDE));
                }
            } catch (Exception ignored) {
            }
        }
    }

    private void onCountdownFinished() {
        timerRunning = false;
        accumulatedMs = totalMs;
        alarming = true;
        wake();
        playSound(RingtoneManager.TYPE_NOTIFICATION, false, 4000L,
                new long[]{0, 400, 200, 400, 200, 400});
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
        skipUntil = phase != PHASE_WORK ? now + 10000L : 0L;
        resetArmUntil = 0L;
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

    private void pub(String t, String l, float pr, int rc, boolean hl, boolean ps, int face, int kind,
                     float hh, float mm, float ss, boolean sh) {
        dText = t;
        dLabel = l;
        dProg = pr;
        dRing = rc;
        dHl = hl;
        dPaused = ps;
        dFace = face;
        dKind = kind;
        dHour = hh;
        dMin = mm;
        dSecA = ss;
        dSecHand = sh;
        dClock = mode == Prefs.MODE_CLOCK;
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
            if (Prefs.getInt(prefs, Prefs.LOOK) == 1) {
                int face = Prefs.getInt(prefs, Prefs.AFACE);
                Calendar cal = Calendar.getInstance();
                float sec = cal.get(Calendar.SECOND) + cal.get(Calendar.MILLISECOND) / 1000f;
                float min = cal.get(Calendar.MINUTE) + sec / 60f;
                float hr = (cal.get(Calendar.HOUR) % 12) + min / 60f;
                pub("", null, -1f, 0, false, false, face, 0, hr * 30f, min * 6f, sec * 6f, clockSec);
                bubble.setPaused(false);
                bubble.setDial(face, 0, -1f, hr * 30f, min * 6f, sec * 6f, clockSec, null, null, 0, false);
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
        if (mode == Prefs.MODE_POMODORO && now < resetArmUntil) lbl = "HOLD AGAIN: RESET ALL";
        long skipLeft = (mode == Prefs.MODE_POMODORO && phase != PHASE_WORK && !alarming) ? skipUntil - now : 0L;
        bubble.setSkip(skipLeft > 0L ? Math.min(1f, skipLeft / 1500f) : 0f);
        dBreak = mode == Prefs.MODE_POMODORO && phase != PHASE_WORK;
        bubble.setPaused(mode != Prefs.MODE_CLOCK && !timerRunning && !alarming && prog >= 0f);
        boolean isPaused = mode != Prefs.MODE_CLOCK && !timerRunning && !alarming && prog >= 0f;
        boolean analogLook = Prefs.getInt(prefs, Prefs.LOOK) == 1;
        pub(text, lbl, prog, ringOverride, flash, isPaused, analogLook ? Prefs.getInt(prefs, Prefs.AFACE) : -1,
                mode == Prefs.MODE_STOPWATCH ? 2 : 1, 0f, 0f, 0f, false);
        if (Prefs.getInt(prefs, Prefs.LOOK) == 1) {
            bubble.setDial(Prefs.getInt(prefs, Prefs.AFACE), mode == Prefs.MODE_STOPWATCH ? 2 : 1,
                    prog < 0f ? 0f : prog, 0f, 0f, 0f, false, text, lbl, ringOverride, flash);
            return;
        }
        bubble.setState(text, lbl, prog, ringOverride, flash);
    }

    // ------------------------------------------------------------ sound and vibration

    private void playSound(int type, boolean loop, long timeoutMs, long[] pattern) {
        stopAlarmSound();
        boolean loud = false;
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

    /** Quiet when the phone is on silent/vibrate or Do Not Disturb, . */
    private boolean soundAllowed() {
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
            ViewGroup.LayoutParams clp = ch.getLayoutParams();
            int wSpec = (clp != null && clp.width > 0)
                    ? MeasureSpec.makeMeasureSpec(clp.width, MeasureSpec.EXACTLY)
                    : MeasureSpec.makeMeasureSpec(maxW, MeasureSpec.AT_MOST);
            int hSpec = (clp != null && clp.height > 0)
                    ? MeasureSpec.makeMeasureSpec(clp.height, MeasureSpec.EXACTLY)
                    : MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED);
            ch.measure(wSpec, hSpec);
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

/** Five-step quick guide shown on first launch and from Settings. */
public class GuideActivity extends Activity {
    private static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT;
    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;
    private static final int STEPS = 5;

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
            body.setText("Android asks once. Turn on \"Display over other apps\" so the timer can float over "
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
            title.setText("Choose your time");
            body.setText("Pick Timer, Stopwatch, Pomodoro or Clock at the top. Then tap a number to type your "
                    + "own time, or tap a preset.");
            addGesture("Tap a mode", "Timer, Stopwatch, Pomodoro, Clock");
            addGesture("Tap a number", "type your own");
            addGesture("Tap a preset", "load it in one tap");
        } else if (step == 2) {
            title.setText("Start");
            body.setText("Tap Start floating timer. The bubble stays on top while you use other apps.");
            BubbleView bv = new BubbleView(this);
            bv.applyPrefs(p);
            bv.setState("25:00", "FOCUS 1/4", 0.65f, 0, false);
            art.addView(bv, new LinearLayout.LayoutParams(WRAP, WRAP));
        } else if (step == 3) {
            title.setText("Use the bubble");
            body.setText("Everything works right on the bubble.");
            addGesture("Tap", "pause or resume");
            addGesture("Hold", "restart");
            addGesture("Drag", "move it anywhere");
            addGesture("Drop on \u2715", "close it");
        } else {
            title.setText("Make it yours");
            body.setText("Open the Style tab for colours, shape and size. The Stats tab shows your goal, streak "
                    + "and stars. More tips are in Settings.");
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
cat > 'app/src/main/java/com/floaty/timer/MainActivity.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Paint;
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
    private ImageView soundBtn;
    private ImageView vibBtn;
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
            // brand new install: the guide covers everything, so there is nothing "new" to show yet
            p.edit().putInt(Prefs.GUIDE_SEEN, 1).putInt(Prefs.WHATS_SEEN, WhatsNew.VERSION).apply();
            startActivity(new Intent(this, GuideActivity.class));
        } else {
            WhatsNew.showIfNew(this, p, ui.dark);
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
        publishShortcuts();
        WatchuWidget.refresh(this);
        if (tab == 2) fillStats();
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
        ImageView deskTop = ui.icon(R.drawable.ic_desk, 24, ui.variant);
        deskTop.setPadding(dp(8), dp(8), dp(8), dp(8));
        deskTop.setContentDescription("Desk mode");
        deskTop.setOnClickListener(v -> openDesk());
        top.addView(deskTop, new LinearLayout.LayoutParams(dp(44), dp(44)));
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
        LinearLayout startWrap = ui.horizontal();
        startWrap.setGravity(Gravity.CENTER_VERTICAL);
        startWrap.setPadding(dp(16), dp(8), dp(16), dp(12));
        soundBtn = toggleIcon(Prefs.SOUND, R.drawable.ic_sound_on, R.drawable.ic_sound_off, "Sound");
        vibBtn = toggleIcon(Prefs.VIBRATE, R.drawable.ic_vib_on, R.drawable.ic_vib_off, "Vibration");
        startWrap.addView(soundBtn, lp(dp(56), dp(56), 0, 0, 10, 0));
        startWrap.addView(vibBtn, lp(dp(56), dp(56), 0, 0, 10, 0));
        startWrap.addView(startBar, new LinearLayout.LayoutParams(0, dp(56), 1f));
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

    /** A square on/off button for sound or vibration, shown beside the start button. */
    private ImageView toggleIcon(final String key, final int onRes, final int offRes, final String name) {
        final ImageView iv = new ImageView(this);
        iv.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
        iv.setPadding(dp(16), dp(16), dp(16), dp(16));
        iv.setContentDescription(name);
        paintToggle(iv, key, onRes, offRes);
        iv.setOnClickListener(v -> {
            boolean on = Prefs.getInt(p, key) == 1;
            p.edit().putInt(key, on ? 0 : 1).apply();
            paintToggle(iv, key, onRes, offRes);
            Toast.makeText(this, name + (on ? " off" : " on"), Toast.LENGTH_SHORT).show();
        });
        return iv;
    }

    private void paintToggle(ImageView iv, String key, int onRes, int offRes) {
        boolean on = Prefs.getInt(p, key) == 1;
        iv.setImageResource(on ? onRes : offRes);
        iv.setImageTintList(ColorStateList.valueOf(on ? ui.primary : ui.variant));
        iv.setBackground(ui.outlined(on ? ui.secC : 0x00000000, on ? ui.primary : ui.outline, 14));
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
        if (t == 2) fillStats();
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
        c.setBackground(ui.outlined(ui.container, ui.line, 20));
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
        card.setBackground(ui.outlined(ui.container, ui.line, 24));
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
        Prefs.clampBreaks(p);
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
            card.addView(stepper("Short break", Prefs.POMO_SHORT, 1, Prefs.getInt(p, Prefs.LIMIT_BREAKS) == 1 ? Prefs.maxShort(p) : 60, 1, "min", N_CONFIG));
            card.addView(divider());
            card.addView(stepper("Long break", Prefs.POMO_LONG, 1, Prefs.getInt(p, Prefs.LIMIT_BREAKS) == 1 ? Prefs.maxLong(p) : 120, 1, "min", N_CONFIG));
            card.addView(divider());
            card.addView(stepper("Rounds before long break", Prefs.POMO_ROUNDS, 1, 12, 1, "", N_CONFIG));
            if (Prefs.getInt(p, Prefs.LIMIT_BREAKS) == 1) {
                int ms = Prefs.maxShort(p);
                int ml = Prefs.maxLong(p);
                boolean over = Prefs.getInt(p, Prefs.POMO_SHORT) > ms || Prefs.getInt(p, Prefs.POMO_LONG) > ml;
                TextView note = ui.text((over ? "Breaks over " + ms + " min (long: " + ml + " min) are not Pomodoro, "
                        + "so they are shortened. Use Timer for longer rests."
                        : "Breaks are capped at " + ms + " min, long breaks at " + ml + " min. Change in Settings."),
                        13, ui.variant);
                note.setPadding(0, dp(8), 0, dp(8));
                card.addView(note);
            }
        } else {
            if (Prefs.getInt(p, Prefs.LOOK) == 0) {
                card.addView(ui.switchRow("24-hour clock", null, Prefs.getInt(p, Prefs.CLOCK_24) == 1,
                        (b, on) -> {
                            p.edit().putInt(Prefs.CLOCK_24, on ? 1 : 0).apply();
                            changed(N_STYLE);
                        }));
                card.addView(divider());
            }
            card.addView(ui.switchRow("Show seconds", null, Prefs.getInt(p, Prefs.CLOCK_SEC) == 1,
                    (b, on) -> {
                        p.edit().putInt(Prefs.CLOCK_SEC, on ? 1 : 0).apply();
                        changed(N_STYLE);
                    }));
        }
        timerBox.addView(card, lp(MATCH, WRAP, 0, 0, 0, 0));
        if (mode == Prefs.MODE_COUNTDOWN || mode == Prefs.MODE_POMODORO) {
            TextView hint = ui.text("Tap a number to type your own value.", 12, ui.variant);
            hint.setGravity(Gravity.CENTER);
            timerBox.addView(hint, lp(MATCH, WRAP, 0, 8, 0, 0));
        }
        LinearLayout deskRow = ui.horizontal();
        deskRow.setGravity(Gravity.CENTER_VERTICAL);
        deskRow.setBackground(ui.outlined(ui.container, ui.line, 20));
        deskRow.setPadding(dp(16), dp(14), dp(16), dp(14));
        deskRow.addView(ui.icon(R.drawable.ic_desk, 24, ui.primary), lp(dp(24), dp(24), 0, 0, 14, 0));
        LinearLayout deskTxt = ui.vertical();
        deskTxt.addView(ui.medium("Desk mode", 16, ui.onSurface));
        deskTxt.addView(ui.text("Use this screen as a big desk clock", 13, ui.variant));
        deskRow.addView(deskTxt, new LinearLayout.LayoutParams(0, WRAP, 1f));
        deskRow.addView(ui.medium("Open", 14, ui.primary));
        deskRow.setOnClickListener(v -> openDesk());
        timerBox.addView(deskRow, lp(MATCH, WRAP, 0, 14, 0, 0));
        refreshPreview();
    }

    /** One row: label, minus button, fixed-width value, plus button. Every row lines up. */
    private LinearLayout stepper(final String label, final String key, final int min, final int max,
                                 final int step, final String unit, final int notify) {
        LinearLayout row = ui.horizontal();
        row.setMinimumHeight(dp(56));
        row.addView(ui.text(label, 16, ui.onSurface), new LinearLayout.LayoutParams(0, WRAP, 1f));
        final TextView value = ui.medium(valueText(Prefs.getInt(p, key), unit), 16, ui.onSurface);
        value.setGravity(Gravity.CENTER);
        value.setPaintFlags(value.getPaintFlags() | Paint.UNDERLINE_TEXT_FLAG);
        value.setOnClickListener(v -> askNumber(label, key, min, max, value, unit, notify));
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

    /** Lets the user type a number. It is kept inside the allowed range. */
    private void askNumber(String label, final String key, final int min, final int max,
                           final TextView value, final String unit, final int notify) {
        final EditText et = new EditText(this);
        et.setInputType(InputType.TYPE_CLASS_NUMBER);
        et.setSingleLine(true);
        et.setText(String.valueOf(Prefs.getInt(p, key)));
        et.setSelectAllOnFocus(true);
        FrameLayout box = new FrameLayout(this);
        box.setPadding(dp(20), dp(8), dp(20), 0);
        box.addView(et, new FrameLayout.LayoutParams(MATCH, WRAP));
        dialog().setTitle(label + " (" + min + " to " + max + ")").setView(box)
                .setPositiveButton("OK", (d, which) -> {
                    int v;
                    try {
                        v = Integer.parseInt(et.getText().toString().trim());
                    } catch (Exception e) {
                        return;
                    }
                    if (v < min || v > max) {
                        v = v < min ? min : max;
                        Toast.makeText(this, "Allowed: " + min + " to " + max, Toast.LENGTH_SHORT).show();
                    }
                    p.edit().putInt(key, v).apply();
                    value.setText(valueText(v, unit));
                    if (key.startsWith("pomo_") && Prefs.clampBreaks(p)) fillTimer();
                    changed(notify);
                })
                .setNegativeButton("Cancel", null).show();
    }

    private void bump(String key, int delta, int min, int max, TextView value, String unit, int notify) {
        int v = Prefs.getInt(p, key) + delta;
        if (v < min) v = min;
        if (v > max) v = max;
        p.edit().putInt(key, v).apply();
        value.setText(valueText(v, unit));
        if (key.startsWith("pomo_") && Prefs.clampBreaks(p)) fillTimer();
        changed(notify);
    }

    // ------------------------------------------------------------ presets

    private void buildPresets(LinearLayout box) {
        box.addView(ui.medium("Presets", 14, ui.variant), lp(MATCH, WRAP, 0, 0, 0, 6));

        android.widget.HorizontalScrollView hs = new android.widget.HorizontalScrollView(this);
        hs.setHorizontalScrollBarEnabled(false);
        LinearLayout row = ui.horizontal();
        row.setGravity(Gravity.CENTER_VERTICAL);
        hs.addView(row, new FrameLayout.LayoutParams(WRAP, WRAP));

        TextView plus = ui.chip("+  Save", false, true);
        plus.setOnClickListener(v -> askName("Save current setup", "My preset", name -> saveCurrent(name)));
        row.addView(plus, lp(WRAP, WRAP, 0, 0, 8, 0));

        List<String> hidden = Presets.hidden(p);
        for (final Presets.Preset x : Presets.builtIns()) {
            if (hidden.contains(x.name)) continue;
            row.addView(presetChip(x), lp(WRAP, WRAP, 0, 0, 8, 0));
        }
        for (final Presets.Preset x : Presets.saved(p)) {
            row.addView(presetChip(x), lp(WRAP, WRAP, 0, 0, 8, 0));
        }
        if (editPresets && !hidden.isEmpty()) {
            TextView restore = ui.chip("Restore hidden", false, true);
            restore.setOnClickListener(v -> {
                Presets.writeHidden(p, new java.util.ArrayList<String>());
                fillTimer();
            });
            row.addView(restore, lp(WRAP, WRAP, 0, 0, 8, 0));
        }
        TextView more = ui.chip(editPresets ? "Done" : "\u22EF  Edit", editPresets, true);
        more.setOnClickListener(v -> {
            editPresets = !editPresets;
            fillTimer();
        });
        row.addView(more, lp(WRAP, WRAP, 0, 0, 0, 0));
        box.addView(hs, lp(MATCH, WRAP, 0, 0, 0, 6));
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

        // look: digital or analog
        final boolean analog = Prefs.getInt(p, Prefs.LOOK) == 1;
        styleBox.addView(labelled("Look", ui.segmented(new String[]{"Digital", "Analog"}, analog ? 1 : 0, v -> {
            p.edit().putInt(Prefs.LOOK, v).apply();
            fillStyle();
            fillTimer();
            changed(N_STYLE);
        })), lp(MATCH, WRAP, 0, 0, 0, 10));
        if (analog) {
            styleBox.addView(labelled("Face", ui.segmented(new String[]{"Classic", "Minimal", "Wedge", "Ring"},
                    Prefs.getInt(p, Prefs.AFACE), v -> {
                        p.edit().putInt(Prefs.AFACE, v).apply();
                        changed(N_STYLE);
                    })), lp(MATCH, WRAP, 0, 0, 0, 10));
        }

        // shape
        styleBox.addView(labelled("Shape", shapeSegment()), lp(MATCH, WRAP, 0, 0, 0, 10));

        // font
        if (!analog) {
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
        }

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
        if (customOpen) styleBox.addView(customPanel(colorTarget), lp(MATCH, WRAP, 0, 0, 0, 10));

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
        TextView custom = ui.chip(customOpen ? "Close custom colour" : "+  Custom colour", customOpen, true);
        custom.setOnClickListener(v -> {
            customOpen = !customOpen;
            fillStyle();
        });
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
    private boolean customOpen = false;

    private View customPanel(final int target) {
        final float[] hsv = new float[3];
        Color.colorToHSV(Prefs.getInt(p, COLOR_KEYS[target]), hsv);

        LinearLayout box = ui.vertical();
        box.setPadding(dp(14), dp(12), dp(14), dp(12));
        box.setBackground(ui.outlined(ui.container, ui.line, 16));
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

        LinearLayout btns = ui.horizontal();
        TextView use = ui.chip("Use this colour", true, false);
        use.setOnClickListener(v -> {
            if (tryColor(target, Color.HSVToColor(hsv))) {
                customOpen = false;
                fillStyle();
            }
        });
        TextView close = ui.chip("Close", false, false);
        close.setOnClickListener(v -> {
            customOpen = false;
            fillStyle();
        });
        btns.addView(use, lp(WRAP, WRAP, 0, 0, 8, 0));
        btns.addView(close, lp(WRAP, WRAP, 0, 0, 0, 0));
        box.addView(btns, lp(MATCH, WRAP, 0, 10, 0, 0));
        return box;
    }

    // ------------------------------------------------------------ stats tab

    private LinearLayout statsBox;

    private View buildStatsPage() {
        ScrollView sv = new ScrollView(this);
        statsBox = ui.vertical();
        statsBox.setPadding(dp(16), dp(4), dp(16), dp(16));
        sv.addView(statsBox, new FrameLayout.LayoutParams(MATCH, WRAP));
        fillStats();
        return sv;
    }

    private TextView statLine(String big, String small, int bigColor) {
        TextView t = ui.medium(big, 22, bigColor);
        t.setGravity(Gravity.CENTER);
        return t;
    }

    private void fillStats() {
        if (statsBox == null) return;
        statsBox.removeAllViews();
        Stats.evaluate(p);
        final java.util.TreeMap<Integer, Integer> m = Stats.load(p);
        final int goalMin = Prefs.getInt(p, Prefs.GOAL_MIN);
        final int goal = goalMin * 60;
        final int today = Stats.secs(m, Stats.cal(0));
        final int streak = Stats.streak(m, goal);
        final int stars = Prefs.getInt(p, Prefs.STARS);
        final int run = Prefs.getInt(p, Prefs.STAR_RUN);
        final int thisWeek = Stats.sumDays(m, -6, 0);
        final int lastWeek = Stats.sumDays(m, -13, -7);
        final int green = 0xFF6FD3A0;
        final int red = 0xFFE5707E;

        // exam countdown
        int examKey = p.getInt(Prefs.EXAM_DATE, 0);
        int examLeft = Stats.examDays(p);
        if (examKey != 0 && examLeft < 0) {
            p.edit().remove(Prefs.EXAM_DATE).apply();
            examKey = 0;
        }
        LinearLayout cx = card();
        cx.setPadding(dp(16), dp(14), dp(16), dp(14));
        if (examKey != 0) {
            cx.addView(ui.medium("Exam", 14, ui.variant), lp(MATCH, WRAP, 0, 0, 0, 2));
            int weekAvg = thisWeek / 7;
            int examCol = Charts.status(weekAvg, goal);
            int avgPct = goal > 0 ? Math.round(weekAvg * 100f / goal) : 0;
            cx.addView(ui.medium(examLeft == 0 ? "Exam day" : examLeft + (examLeft == 1 ? " day left" : " days left"),
                    28, examCol));
            cx.addView(ui.text("Last 7 days: " + avgPct + "% of your daily goal", 13, examCol),
                    lp(MATCH, WRAP, 0, 2, 0, 0));
            cx.addView(ui.text(new SimpleDateFormat("d MMM yyyy", Locale.getDefault())
                    .format(Stats.fromKey(examKey).getTime()), 13, ui.variant), lp(MATCH, WRAP, 0, 2, 0, 8));
            LinearLayout er = ui.horizontal();
            TextView change = ui.chip("Change date", false, true);
            change.setOnClickListener(v -> pickExamDate());
            TextView remove = ui.chip("Remove", false, true);
            remove.setOnClickListener(v -> {
                p.edit().remove(Prefs.EXAM_DATE).apply();
                fillStats();
            });
            er.addView(change, lp(WRAP, WRAP, 0, 0, 8, 0));
            er.addView(remove);
            cx.addView(er);
        } else {
            LinearLayout er = ui.horizontal();
            er.setGravity(Gravity.CENTER_VERTICAL);
            LinearLayout tx = ui.vertical();
            tx.addView(ui.medium("Exam countdown", 16, ui.onSurface));
            tx.addView(ui.text("Count the days to your exam", 13, ui.variant));
            er.addView(tx, new LinearLayout.LayoutParams(0, WRAP, 1f));
            TextView setDate = ui.chip("Set date", true, true);
            setDate.setOnClickListener(v -> pickExamDate());
            er.addView(setDate);
            cx.addView(er);
        }
        statsBox.addView(cx, lp(MATCH, WRAP, 0, 0, 0, 12));

        // today and goal
        LinearLayout c1 = card();
        c1.setPadding(dp(16), dp(12), dp(16), dp(14));
        LinearLayout head = ui.horizontal();
        head.setGravity(Gravity.CENTER_VERTICAL);
        head.addView(ui.medium("Today", 14, ui.variant), new LinearLayout.LayoutParams(0, WRAP, 1f));
        TextView goalChip = ui.chip("Goal " + Stats.dur(goal) + "  \u25BE", false, true);
        goalChip.setOnClickListener(v -> pickGoal(goalMin));
        head.addView(goalChip);
        c1.addView(head, lp(MATCH, WRAP, 0, 0, 0, 8));
        RingView ring = new RingView(this);
        ring.frac = goal > 0 ? today / (float) goal : 0f;
        ring.big = Stats.dur(today);
        ring.small = "of " + Stats.dur(goal);
        ring.trackColor = ui.line;
        ring.arcColor = Charts.status(today, goal);
        ring.textColor = ui.onSurface;
        ring.subColor = ui.variant;
        c1.addView(ring, lp(dp(170), dp(170), 0, 0, 0, 6));
        ((LinearLayout.LayoutParams) ring.getLayoutParams()).gravity = Gravity.CENTER_HORIZONTAL;
        TextView msg = ui.text(today >= goal ? "Goal reached today. Nice work."
                : Stats.dur(goal - today) + " to go", 14, today >= goal ? green : ui.variant);
        msg.setGravity(Gravity.CENTER);
        c1.addView(msg, lp(MATCH, WRAP, 0, 0, 0, 0));
        statsBox.addView(c1, lp(MATCH, WRAP, 0, 0, 0, 12));

        // streak and stars
        LinearLayout c2 = card();
        c2.setPadding(dp(16), dp(14), dp(16), dp(14));
        LinearLayout two = ui.horizontal();
        LinearLayout colA = ui.vertical();
        colA.setGravity(Gravity.CENTER);
        colA.addView(ui.text("Streak", 13, ui.variant));
        colA.addView(ui.medium(streak + (streak == 1 ? " day" : " days"), 22, ui.onSurface));
        LinearLayout colB = ui.vertical();
        colB.setGravity(Gravity.CENTER);
        colB.addView(ui.text("Stars", 13, ui.variant));
        colB.addView(ui.medium("\u2605 " + stars, 22, 0xFFD8A67C));
        colB.addView(ui.text(run + " of 10 days toward the next", 12, ui.variant));
        two.addView(colA, new LinearLayout.LayoutParams(0, WRAP, 1f));
        two.addView(colB, new LinearLayout.LayoutParams(0, WRAP, 1f));
        c2.addView(two);
        statsBox.addView(c2, lp(MATCH, WRAP, 0, 0, 0, 12));

        // last 14 days, stock style
        final int wkPct = Stats.weekPct(thisWeek, lastWeek);
        final int wkCol = Charts.trend(wkPct);
        LinearLayout c3 = card();
        c3.setPadding(dp(16), dp(12), dp(16), dp(12));
        LinearLayout h3 = ui.horizontal();
        h3.setGravity(Gravity.CENTER_VERTICAL);
        h3.addView(ui.medium("Last 14 days", 14, ui.variant), new LinearLayout.LayoutParams(0, WRAP, 1f));
        h3.addView(ui.medium(Stats.trendWord(wkPct), 13, wkCol));
        c3.addView(h3, lp(MATCH, WRAP, 0, 0, 0, 8));
        StockView sv = new StockView(this);
        sv.goalSec = goal;
        sv.secs = Stats.lastDays(m, 14);
        sv.surface = ui.container;
        sv.textColor = ui.variant;
        sv.textStrong = ui.onSurface;
        c3.addView(sv, lp(MATCH, dp(220), 0, 0, 0, 6));
        c3.addView(ui.text("Green: goal met. Amber: half or more. Red: under half. Dashed line: your goal.", 12,
                ui.variant));
        statsBox.addView(c3, lp(MATCH, WRAP, 0, 0, 0, 12));

        // this week vs last week
        LinearLayout c4 = card();
        c4.setPadding(dp(16), dp(12), dp(16), dp(12));
        c4.addView(ui.medium("This week vs last week", 14, ui.variant), lp(MATCH, WRAP, 0, 0, 0, 6));
        String wkText = wkPct == Stats.NO_PCT ? "New"
                : (wkPct > 0 ? "\u25B2 " : wkPct < 0 ? "\u25BC " : "") + Stats.pctText(wkPct);
        TextView wk = ui.medium(wkText, 22, wkCol);
        c4.addView(wk);
        c4.addView(ui.text("This week " + Stats.dur(thisWeek) + "  \u00B7  Last week " + Stats.dur(lastWeek),
                13, ui.variant), lp(MATCH, WRAP, 0, 2, 0, 0));
        statsBox.addView(c4, lp(MATCH, WRAP, 0, 0, 0, 12));

        // month calendar
        LinearLayout c5 = card();
        c5.setPadding(dp(12), dp(12), dp(12), dp(12));
        java.util.Calendar now = java.util.Calendar.getInstance();
        c5.addView(ui.medium(new SimpleDateFormat("MMMM yyyy", Locale.getDefault()).format(now.getTime()),
                14, ui.variant), lp(MATCH, WRAP, 4, 0, 0, 8));
        String[] dn = {"M", "T", "W", "T", "F", "S", "S"};
        LinearLayout hrow = ui.horizontal();
        for (String d : dn) {
            TextView t = ui.text(d, 12, ui.variant);
            t.setGravity(Gravity.CENTER);
            hrow.addView(t, new LinearLayout.LayoutParams(0, WRAP, 1f));
        }
        c5.addView(hrow, lp(MATCH, WRAP, 0, 0, 0, 4));
        java.util.Calendar first = java.util.Calendar.getInstance();
        first.set(java.util.Calendar.DAY_OF_MONTH, 1);
        int lead = (first.get(java.util.Calendar.DAY_OF_WEEK) + 5) % 7;
        int days = now.getActualMaximum(java.util.Calendar.DAY_OF_MONTH);
        int todayDom = now.get(java.util.Calendar.DAY_OF_MONTH);
        int cell = 0;
        LinearLayout row = null;
        for (int i = 0; i < lead + days; i++) {
            if (i % 7 == 0) {
                row = ui.horizontal();
                c5.addView(row, lp(MATCH, WRAP, 0, 0, 0, 4));
            }
            int dom = i - lead + 1;
            TextView t = ui.text(dom >= 1 ? String.valueOf(dom) : "", 13, ui.variant);
            t.setGravity(Gravity.CENTER);
            if (dom >= 1) {
                java.util.Calendar dc = java.util.Calendar.getInstance();
                dc.set(java.util.Calendar.DAY_OF_MONTH, dom);
                int sec = Stats.secs(m, dc);
                if (dom < todayDom) {
                    if (sec >= goal) {
                        t.setBackground(ui.rounded(ui.greenC, 10));
                        t.setTextColor(ui.onGreenC);
                    } else {
                        t.setBackground(ui.rounded(0x33E5707E, 10));
                        t.setTextColor(ui.onSurface);
                    }
                } else if (dom == todayDom) {
                    t.setBackground(ui.outlined(0x00000000, ui.primary, 10));
                    t.setTextColor(ui.onSurface);
                }
            }
            row.addView(t, new LinearLayout.LayoutParams(0, dp(34), 1f));
            cell++;
        }
        statsBox.addView(c5, lp(MATCH, WRAP, 0, 0, 0, 12));

        // share
        LinearLayout share = ui.horizontal();
        share.setGravity(Gravity.CENTER);
        share.setBackground(ui.rounded(ui.primary, 14));
        share.setPadding(dp(16), dp(14), dp(16), dp(14));
        TextView st = ui.medium("Share report card", 16, ui.onPrimary);
        share.addView(st);
        share.setOnClickListener(v -> shareReport(goal, today, streak, stars, run, thisWeek, lastWeek, m));
        statsBox.addView(share, lp(MATCH, WRAP, 0, 0, 0, 8));
    }

    private void pickExamDate() {
        java.util.Calendar c = Stats.cal(30);
        int ek = p.getInt(Prefs.EXAM_DATE, 0);
        if (ek != 0) c = Stats.fromKey(ek);
        int theme = ui.dark ? android.R.style.Theme_DeviceDefault_Dialog_Alert
                : android.R.style.Theme_DeviceDefault_Light_Dialog_Alert;
        android.app.DatePickerDialog dp = new android.app.DatePickerDialog(this, theme,
                (view, y, m, d) -> {
                    p.edit().putInt(Prefs.EXAM_DATE, y * 10000 + (m + 1) * 100 + d).apply();
                    fillStats();
                }, c.get(java.util.Calendar.YEAR), c.get(java.util.Calendar.MONTH),
                c.get(java.util.Calendar.DAY_OF_MONTH));
        dp.getDatePicker().setMinDate(System.currentTimeMillis() - 1000L);
        dp.show();
    }

    private void pickGoal(final int currentMin) {
        final int[] mins = {30, 60, 90, 120, 180, 240, 300, 360, 480, 600};
        String[] labels = new String[mins.length + 1];
        for (int i = 0; i < mins.length; i++) labels[i] = Stats.dur(mins[i] * 60);
        labels[mins.length] = "Custom (hours and minutes)";
        dialog().setTitle("Daily goal").setItems(labels, (d, which) -> {
            if (which < mins.length) {
                confirmGoal(currentMin, mins[which]);
            } else {
                LinearLayout box = ui.horizontal();
                box.setGravity(Gravity.CENTER_VERTICAL);
                box.setPadding(dp(22), dp(8), dp(22), 0);
                final android.widget.EditText hh = new android.widget.EditText(this);
                hh.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
                hh.setHint("0");
                hh.setText(String.valueOf(currentMin / 60));
                hh.setGravity(Gravity.CENTER);
                final android.widget.EditText mm = new android.widget.EditText(this);
                mm.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
                mm.setHint("0");
                mm.setText(String.valueOf(currentMin % 60));
                mm.setGravity(Gravity.CENTER);
                TextView hl = ui.text("hours", 15, ui.variant);
                TextView ml = ui.text("minutes", 15, ui.variant);
                box.addView(hh, new LinearLayout.LayoutParams(dp(64), WRAP));
                box.addView(hl, lp(WRAP, WRAP, 8, 0, 16, 0));
                box.addView(mm, new LinearLayout.LayoutParams(dp(64), WRAP));
                box.addView(ml, lp(WRAP, WRAP, 8, 0, 0, 0));
                dialog().setTitle("Daily goal (10 minutes to 24 hours)").setView(box)
                        .setPositiveButton("OK", (d2, w2) -> {
                            int h = 0;
                            int m = 0;
                            try {
                                String hs = hh.getText().toString().trim();
                                String ms = mm.getText().toString().trim();
                                if (hs.length() > 0) h = Integer.parseInt(hs);
                                if (ms.length() > 0) m = Integer.parseInt(ms);
                            } catch (NumberFormatException e) {
                                return;
                            }
                            int v = h * 60 + m;
                            if (v < 10) v = 10;
                            if (v > 1440) v = 1440;
                            confirmGoal(currentMin, v);
                        }).setNegativeButton("Cancel", null).show();
            }
        }).setNegativeButton("Cancel", null).show();
    }

    private void confirmGoal(final int currentMin, final int newMin) {
        if (newMin == currentMin) return;
        dialog().setTitle("Change daily goal?")
                .setMessage("Changing your goal restarts your stars. Your earned stars go back to 0 and counting begins again today.")
                .setPositiveButton("Change and restart", (d, w) -> {
                    Stats.setGoal(p, newMin);
                    fillStats();
                })
                .setNegativeButton("Keep " + Stats.dur(currentMin * 60), null).show();
    }

    private void shareReport(int goal, int today, int streak, int stars, int run, int thisWeek,
                             int lastWeek, java.util.Map<Integer, Integer> m) {
        int[] last14 = new int[14];
        for (int i = 0; i < 14; i++) last14[i] = Stats.secs(m, Stats.cal(i - 13));
        String text = "My Watchu report: " + Stats.dur(today) + " of " + Stats.dur(goal) + " today, "
                + streak + "-day streak, " + stars + " star" + (stars == 1 ? "" : "s") + ". Watchu is free for life. Get it: https://github.com/Fury5645/floaty/releases/latest";
        Intent send = new Intent(Intent.ACTION_SEND);
        try {
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                android.graphics.Bitmap bmp = ReportCard.render(goal, today, streak, stars, run, thisWeek,
                        lastWeek, last14, Stats.examDays(p));
                android.content.ContentValues cv = new android.content.ContentValues();
                cv.put(android.provider.MediaStore.Images.Media.DISPLAY_NAME,
                        "watchu-report-" + System.currentTimeMillis() + ".png");
                cv.put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png");
                cv.put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Watchu");
                Uri u = getContentResolver().insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv);
                if (u == null) throw new java.io.IOException("no uri");
                java.io.OutputStream os = getContentResolver().openOutputStream(u);
                bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, os);
                os.close();
                send.setType("image/png");
                send.putExtra(Intent.EXTRA_STREAM, u);
                send.putExtra(Intent.EXTRA_TEXT, text);
                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            } else {
                send.setType("text/plain");
                send.putExtra(Intent.EXTRA_TEXT, text);
            }
        } catch (Exception e) {
            send = new Intent(Intent.ACTION_SEND);
            send.setType("text/plain");
            send.putExtra(Intent.EXTRA_TEXT, text);
        }
        startActivity(Intent.createChooser(send, "Share report card"));
    }

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
            if (Prefs.getInt(p, Prefs.LOOK) == 1) {
                int face = Prefs.getInt(p, Prefs.AFACE);
                Calendar cal = Calendar.getInstance();
                float sec = cal.get(Calendar.SECOND) + cal.get(Calendar.MILLISECOND) / 1000f;
                float min = cal.get(Calendar.MINUTE) + sec / 60f;
                float hr = (cal.get(Calendar.HOUR) % 12) + min / 60f;
                pv.setPaused(false);
                pv.setDial(face, 0, -1f, hr * 30f, min * 6f, sec * 6f,
                        Prefs.getInt(p, Prefs.CLOCK_SEC) == 1, null, null, 0, false);
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
        pv.setPaused(false);
        if (Prefs.getInt(p, Prefs.LOOK) == 1) {
            pv.setDial(Prefs.getInt(p, Prefs.AFACE), m == Prefs.MODE_STOPWATCH ? 2 : 1,
                    prog < 0f ? 0.75f : prog, 0f, 0f, 0f, false, t, l, 0, false);
            return;
        }
        pv.setState(t, l, prog, 0, false);
    }

    private void updateStartBtn() {
        if (startText == null) return;
        if (FloatingService.active) {
            startText.setText("Stop floating timer");
            startText.setTextColor(ui.onSurface);
            startBar.setBackground(ui.rounded(ui.high, 14));
            startIcon.setImageResource(R.drawable.ic_stop);
            startIcon.setImageTintList(ColorStateList.valueOf(ui.onSurface));
        } else {
            startText.setText("Start floating timer");
            startText.setTextColor(ui.onPrimary);
            startBar.setBackground(ui.rounded(ui.primary, 14));
            startIcon.setImageResource(R.drawable.ic_play);
            startIcon.setImageTintList(ColorStateList.valueOf(ui.onPrimary));
        }
    }

    /** The menu you get by pressing and holding the app icon. */
    private void publishShortcuts() {
        try {
            android.content.pm.ShortcutManager sm = getSystemService(android.content.pm.ShortcutManager.class);
            if (sm == null) return;
            List<Presets.Preset> list = QuickStartActivity.visiblePresets(p);
            java.util.ArrayList<android.content.pm.ShortcutInfo> out =
                    new java.util.ArrayList<android.content.pm.ShortcutInfo>();
            android.graphics.drawable.Icon icon = android.graphics.drawable.Icon.createWithResource(this, R.mipmap.ic_launcher);
            for (int i = 0; i < Math.min(2, list.size()); i++) {
                out.add(shortcut("p" + i, list.get(i).name, "Start " + list.get(i).name, "p" + i, icon));
            }
            out.add(shortcut("stopwatch", "Stopwatch", "Start stopwatch", "stopwatch", icon));
            out.add(shortcut("desk", "Desk mode", "Open desk mode", "desk", icon));
            sm.setDynamicShortcuts(out);
        } catch (Exception ignored) {
        }
    }

    private android.content.pm.ShortcutInfo shortcut(String id, String shortLabel, String longLabel, String which,
                                                     android.graphics.drawable.Icon icon) {
        Intent in = new Intent(this, QuickStartActivity.class);
        in.setAction(Intent.ACTION_VIEW);
        in.putExtra(QuickStartActivity.EXTRA, which);
        return new android.content.pm.ShortcutInfo.Builder(this, id)
                .setShortLabel(shortLabel).setLongLabel(longLabel).setIcon(icon).setIntent(in).build();
    }

    private void openDesk() {
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "Turn on \"Display over other apps\" for Watchu, then come back.",
                    Toast.LENGTH_LONG).show();
            startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName())));
            return;
        }
        if (Prefs.getInt(p, Prefs.DESK_NOTICE) == 1) {
            startActivity(new Intent(this, DeskActivity.class));
            return;
        }
        LinearLayout box = ui.vertical();
        box.setPadding(dp(22), dp(8), dp(22), dp(0));
        box.addView(ui.text("Desk mode keeps your screen on, which uses battery. "
                + "Plug in your charger if you will leave it running for long.", 15, ui.onSurface));
        final android.widget.CheckBox again = new android.widget.CheckBox(this);
        again.setText("Don't remind me again");
        again.setTextColor(ui.variant);
        box.addView(again, lp(WRAP, WRAP, 0, 10, 0, 0));
        dialog().setTitle("Before you start").setView(box)
                .setPositiveButton("Start desk mode", (d, which) -> {
                    if (again.isChecked()) p.edit().putInt(Prefs.DESK_NOTICE, 1).apply();
                    startActivity(new Intent(this, DeskActivity.class));
                })
                .setNegativeButton("Cancel", null)
                .show();
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
    /** 0 digital, 1 analog */
    static final String LOOK = "look";
    /** Desk mode: brightness 0 very dim, 1 dim, 2 normal */
    static final String DESK_BRIGHT = "desk_bright";
    static final String DESK_BLACK = "desk_black";
    static final String DESK_MOVE = "desk_move";
    static final String DESK_NOTICE = "desk_notice";
    /** Stats: daily goal in minutes, stars earned, days in the current 10-day run, last day counted. */
    static final String GOAL_MIN = "goal_min";
    /** Exam date as yyyymmdd, 0 when none. */
    static final String EXAM_DATE = "exam_date";
    static final String STARS = "stars";
    static final String STAR_RUN = "star_run";
    static final String LAST_EVAL = "last_eval";
    /** Analog face: 0 Classic, 1 Minimal, 2 Wedge, 3 Ring */
    static final String AFACE = "aface";
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
    static final String LIMIT_BREAKS = "limit_breaks";
    static final String CYCLES = "cycle_counter";
    static final String GUIDE_SEEN = "guide_seen";
    static final String WHATS_SEEN = "whats_seen";
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

    /** Longest short break allowed: a fifth of the focus time, at least 1 minute. */
    static int maxShort(SharedPreferences p) {
        return Math.max(1, getInt(p, POMO_WORK) / 5);
    }

    /** Pulls saved break lengths down to the limits. Returns true if anything changed. */
    static boolean clampBreaks(SharedPreferences p) {
        if (getInt(p, LIMIT_BREAKS) != 1) return false;
        int s = getInt(p, POMO_SHORT);
        int l = getInt(p, POMO_LONG);
        int ns = Math.min(s, maxShort(p));
        int nl = Math.min(l, maxLong(p));
        if (ns == s && nl == l) return false;
        p.edit().putInt(POMO_SHORT, ns).putInt(POMO_LONG, nl).apply();
        return true;
    }

    /** Longest long break allowed: the focus time, at most 30 minutes. */
    static int maxLong(SharedPreferences p) {
        return Math.max(1, Math.min(getInt(p, POMO_WORK), 30));
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
            case LOOK: return 0;
            case DESK_BRIGHT: return 1;
            case DESK_BLACK: return 0;
            case DESK_MOVE: return 0;
            case DESK_NOTICE: return 0;
            case GOAL_MIN: return 180;
            case AFACE: return 0;
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
            case SOUND: return 0;
            case VIBRATE: return 1;
            case LOUD: return 0;
            case POS_X: return -1;
            case POS_Y: return -1;
            case THEME: return THEME_AUTO;
            case LOCK: return 0;
            case SNAP: return 0;
            case FADE: return 0;
            case AUTONEXT: return 0;
            case SKIPPROMPT: return 0;
            case LIMIT_BREAKS: return 1;
            case CYCLES: return 0;
            case GUIDE_SEEN: return 0;
            case TIMER_SECS: return 1;
            case SCREEN_PAUSE: return 0;
            case MOTION_PAUSE: return 0;
            default: return 0;
        }
    }
}
FLOATY_EOF
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
cat > 'app/src/main/java/com/floaty/timer/SettingsActivity.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.StatusBarManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Build;
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
    static final String UPDATE_URL = "https://github.com/Fury5645/floaty/releases/latest/download/Watchu.apk";

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

        LinearLayout c;
        // Appearance
        box.addView(ui.section("Appearance"), ui.lp(MATCH, WRAP, 0, 12, 0, 8));
        c = card(box);
        c.addView(ui.text("Theme", 16, ui.onSurface), ui.lp(MATCH, WRAP, 0, 0, 0, 8));
        c.addView(ui.segmented(new String[]{"Auto", "Light", "Dark", "AMOLED"},
                Prefs.getInt(p, Prefs.THEME), v -> {
                    p.edit().putInt(Prefs.THEME, v).apply();
                    recreate();
                }), ui.lp(MATCH, ui.dp(40), 0, 0, 0, 0));
        c.addView(ui.text("Auto follows your phone. AMOLED is pure black and saves battery on OLED screens.",
                13, ui.variant), ui.lp(MATCH, WRAP, 0, 6, 0, 4));

        // Bubble
        box.addView(ui.section("Bubble"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        c = card(box);
        toggle(c, "Lock position", "Stops accidental dragging", Prefs.LOCK);
        toggle(c, "Snap to edge", "Sticks to the nearest side of the screen", Prefs.SNAP);
        toggle(c, "Fade when idle", "Goes see-through after 5 seconds, solid on touch", Prefs.FADE);
        toggle(c, "Show seconds on timers", "Off shows minutes only, like 25m. Clock has its own switch.",
                Prefs.TIMER_SECS);

        // Pomodoro
        box.addView(ui.section("Pomodoro"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        c = card(box);
        toggle(c, "Auto-start next phase", "Off means it waits for your tap", Prefs.AUTONEXT);
        toggle(c, "\"Skip break?\" prompt", "Shown on the bubble when a break starts", Prefs.SKIPPROMPT);
        toggle(c, "Cycle counter", "Shows the cycle number on the bubble", Prefs.CYCLES);

        // Alerts
        box.addView(ui.section("Alerts"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        c = card(box);
        toggle(c, "Sound", "A short chime. Quiet on silent mode and Do Not Disturb", Prefs.SOUND);
        toggle(c, "Vibration", null, Prefs.VIBRATE);

        // Desk mode
        box.addView(ui.section("Desk mode"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        c = card(box);
        c.addView(ui.text("Brightness", 16, ui.onSurface), ui.lp(MATCH, WRAP, 0, 6, 0, 8));
        c.addView(ui.segmented(new String[]{"Very dim", "Dim", "Normal"}, Prefs.getInt(p, Prefs.DESK_BRIGHT),
                v -> p.edit().putInt(Prefs.DESK_BRIGHT, v).apply()), ui.lp(MATCH, ui.dp(40), 0, 0, 0, 6));
        toggle(c, "Pure black background", "For AMOLED phones. Off gives a very dark grey. Always on with the AMOLED theme.",
                Prefs.DESK_BLACK);
        toggle(c, "Slowly move the clock",
                "Shifts it a little every minute to protect AMOLED phones from burn-in.", Prefs.DESK_MOVE);

        // Advanced
        box.addView(ui.section("Advanced"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        c = card(box);
        toggle(c, "Pause when screen turns off",
                "Resumes when the screen turns on. Not used by Clock.", Prefs.SCREEN_PAUSE);
        toggle(c, "Pause when phone moves",
                "Pauses while the phone is picked up or moved, resumes after 5 still seconds.",
                Prefs.MOTION_PAUSE);

        toggle(c, "Limit Pomodoro breaks",
                "Short breaks up to a fifth of focus time, long breaks up to the focus time (max 30 min).",
                Prefs.LIMIT_BREAKS);

        // Help
        box.addView(ui.section("Help"), ui.lp(MATCH, WRAP, 0, 16, 0, 2));
        c = card(box);
        c.addView(linkRow(R.drawable.ic_help, "Quick guide", "Replay the step-by-step tutorial",
                v -> startActivity(new Intent(this, GuideActivity.class))));
        c.addView(linkRow(R.drawable.ic_help, "More tips", "Handy things the tutorial skips",
                v -> WhatsNew.showTips(this, ui.dark)));
        c.addView(linkRow(R.drawable.ic_plus, "Add to quick settings",
                "Start and pause from the panel you pull down. Tap to add the Watchu tile.",
                v -> addTile()));
        c.addView(linkRow(R.drawable.ic_check, "What's new", "See what changed in this version",
                v -> WhatsNew.showNews(this, ui.dark)));
        c.addView(linkRow(R.drawable.ic_download, "Check for updates",
                "Downloads the newest version. Install it over this one. You have version " + versionText() + ".",
                v -> openLink(UPDATE_URL)));
        c.addView(linkRow(R.drawable.ic_mail, "Send feedback",
                "Opens Telegram (WATCHU HQ). Nothing is sent automatically.",
                v -> openLink(FEEDBACK_URL)));

        // Privacy
        box.addView(ui.section("Privacy"), ui.lp(MATCH, WRAP, 0, 16, 0, 8));
        LinearLayout card = ui.horizontal();
        card.setGravity(Gravity.TOP);
        card.setBackground(ui.rounded(ui.greenC, 20));
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
        LinearLayout lk = card(box);
        lk.addView(linkRow(R.drawable.ic_download, "Download link", "Opens the Watchu download page",
                v -> openLink("https://github.com/Fury5645/floaty/releases/latest")));
        lk.addView(linkRow(R.drawable.ic_mail, "Share app link", "Send the download link to a friend",
                v -> {
                    Intent s = new Intent(Intent.ACTION_SEND);
                    s.setType("text/plain");
                    s.putExtra(Intent.EXTRA_TEXT, "Watchu, a free floating timer. No ads, no premium. "
                            + "https://github.com/Fury5645/floaty/releases/latest");
                    startActivity(Intent.createChooser(s, "Share Watchu"));
                }));
        box.addView(ui.text("Developed by SS", 14, ui.variant), ui.lp(MATCH, WRAP, 0, 2, 0, 0));

        setContentView(frame);
    }

    /** Asks Android to add the Quick Settings tile (Android 13 and newer), otherwise shows how to do it by hand. */
    private void addTile() {
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                StatusBarManager sbm = getSystemService(StatusBarManager.class);
                sbm.requestAddTileService(new ComponentName(this, QuickTileService.class),
                        getString(R.string.app_name),
                        Icon.createWithResource(this, R.drawable.ic_tile),
                        getMainExecutor(),
                        result -> {
                            if (result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED
                                    || result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED) {
                                Toast.makeText(this, "Watchu tile is in Quick Settings", Toast.LENGTH_SHORT).show();
                            }
                        });
                return;
            } catch (Exception ignored) {
            }
        }
        new AlertDialog.Builder(this, ui.dark
                ? android.R.style.Theme_DeviceDefault_Dialog_Alert
                : android.R.style.Theme_DeviceDefault_Light_Dialog_Alert)
                .setTitle("Add the Watchu tile")
                .setMessage("Swipe down twice from the top of the screen to open Quick Settings. "
                        + "Tap the pencil (edit) icon, find Watchu and drag it into your tiles.\n\n"
                        + "Tap the tile to start your first preset. Tap again to pause. Hold it to open the app.")
                .setPositiveButton("Got it", null).show();
    }

    private String versionText() {
        try {
            PackageInfo pi = getPackageManager().getPackageInfo(getPackageName(), 0);
            return pi.versionName + " (build " + pi.versionCode + ")";
        } catch (Exception e) {
            return "";
        }
    }

    private LinearLayout card(LinearLayout box) {
        LinearLayout c = ui.vertical();
        c.setBackground(ui.outlined(ui.container, ui.line, 20));
        c.setPadding(ui.dp(16), ui.dp(6), ui.dp(16), ui.dp(10));
        box.addView(c, ui.lp(MATCH, WRAP, 0, 0, 0, 0));
        return c;
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
            container = black ? 0xFF0D0E11 : 0xFF171C25;
            high = black ? 0xFF1A1C20 : 0xFF272A30;
            onSurface = 0xFFE6E9F0;
            variant = 0xFF8C93A3;
            outline = 0xFF8C93A3;
            primary = 0xFFA9C7FF;
            onPrimary = 0xFF08305F;
            secC = 0xFF3F4759;
            onSecC = 0xFFDBE2F9;
            line = black ? 0xFF22252A : 0xFF232A35;
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
    <string name="widget_desc">Progress today, weekly change, exam countdown and quick-start buttons</string>
</resources>
FLOATY_EOF
cat > 'app/src/main/res/drawable/ic_sound_off.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M4,9.5 v5 h4 l5,4 v-13 l-5,4 z M17,9.5 l5,5 M22,9.5 l-5,5"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
cat > 'app/src/main/res/drawable/ic_sound_on.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M4,9.5 v5 h4 l5,4 v-13 l-5,4 z M16.5,9 a4,4 0 0 1 0,6 M19.5,6.5 a8,8 0 0 1 0,11"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
cat > 'app/src/main/res/drawable/ic_vib_off.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M8,4 h8 a2,2 0 0 1 2,2 v12 a2,2 0 0 1 -2,2 h-8 a2,2 0 0 1 -2,-2 v-12 a2,2 0 0 1 2,-2 z M4,4 l16,16"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
cat > 'app/src/main/res/drawable/ic_vib_on.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M8,4 h8 a2,2 0 0 1 2,2 v12 a2,2 0 0 1 -2,2 h-8 a2,2 0 0 1 -2,-2 v-12 a2,2 0 0 1 2,-2 z M3.5,8 v8 M20.5,8 v8 M1,10.5 v3 M23,10.5 v3"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/DeskActivity.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Color;
import android.os.Bundle;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Map;

/**
 * Full-screen desk clock: a big copy of the bubble on a dark screen that stays on.
 * Tap the clock to pause or resume, hold it to restart, tap the empty space for the buttons.
 */
public class DeskActivity extends Activity {
    private static final float[] LEVELS = {0.03f, 0.12f, 0.35f, 0.7f, 1f};

    private SharedPreferences p;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private BubbleView bv;
    private LinearLayout bar;
    private TextView toggleBtn;
    private TextView resetBtn;
    private TextView skipBtn;
    private TextView info;
    private TextView hint;
    private long infoAt;
    private FrameLayout root;
    private int level;
    private long moveStep = -1L;

    private final Runnable hideBar = new Runnable() {
        @Override
        public void run() {
            bar.setVisibility(View.GONE);
        }
    };

    private final Runnable hideHint = new Runnable() {
        @Override
        public void run() {
            hint.setVisibility(View.GONE);
        }
    };

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            show();
            handler.postDelayed(this, 200L);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        p = Prefs.get(this);
        Window w = getWindow();
        w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        root = new FrameLayout(this);
        boolean black = Prefs.getInt(p, Prefs.DESK_BLACK) == 1
                || Ui.resolveTheme(this, p) == Prefs.THEME_AMOLED;
        root.setBackgroundColor(black ? Color.BLACK : 0xFF0A0C10);

        bv = new BubbleView(this);
        root.addView(bv, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        // today's progress and the exam countdown, under the clock
        info = new TextView(this);
        info.setTextSize(18f);
        info.setGravity(Gravity.CENTER);
        FrameLayout.LayoutParams ilp = new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        ilp.bottomMargin = dp(28);
        root.addView(info, ilp);

        // a short reminder of the gestures, gone after a few seconds
        hint = new TextView(this);
        hint.setTextSize(14f);
        hint.setTextColor(0x99E6E9F0);
        hint.setGravity(Gravity.CENTER);
        FrameLayout.LayoutParams hlp = new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        hlp.topMargin = dp(28);
        root.addView(hint, hlp);

        bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER);
        bar.setBackgroundColor(0xCC000000);
        int pad = dp(10);
        bar.setPadding(pad, pad, pad, pad + dp(8));
        toggleBtn = button("Pause", v -> command(FloatingService.ACTION_TOGGLE));
        resetBtn = button("Reset", v -> command(FloatingService.ACTION_RESET));
        bar.addView(toggleBtn);
        bar.addView(resetBtn);
        skipBtn = button("Skip break", v -> command(FloatingService.ACTION_SKIP));
        bar.addView(skipBtn);
        bar.addView(button("Dimmer", v -> bright(-1)));
        bar.addView(button("Brighter", v -> bright(1)));
        bar.addView(button("Exit", v -> finish()));
        root.addView(bar, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));
        bar.setVisibility(View.GONE);

        root.setOnClickListener(v -> toggleBar());
        bv.setOnClickListener(v -> {
            if (FloatingService.active && !FloatingService.dClock) {
                command(FloatingService.ACTION_TOGGLE);
            } else {
                toggleBar();
            }
        });
        bv.setOnLongClickListener(v -> {
            if (FloatingService.active && !FloatingService.dClock) {
                command(FloatingService.ACTION_RESET);
                return true;
            }
            return false;
        });
        setContentView(root);

        int pref = Prefs.getInt(p, Prefs.DESK_BRIGHT);
        level = pref == 0 ? 0 : (pref == 1 ? 1 : 3);
        applyBrightness();
    }

    private void toggleBar() {
        if (bar.getVisibility() == View.VISIBLE) {
            bar.setVisibility(View.GONE);
            handler.removeCallbacks(hideBar);
        } else {
            bar.setVisibility(View.VISIBLE);
            handler.removeCallbacks(hideBar);
            handler.postDelayed(hideBar, 4000L);
        }
    }

    /** Today against the goal (coloured like the rest of the app) and days left to the exam. */
    private void updateInfo() {
        Map<Integer, Integer> m = Stats.load(p);
        int goal = Prefs.getInt(p, Prefs.GOAL_MIN) * 60;
        int today = Stats.secs(m, Stats.cal(0));
        String a = "Today " + Stats.dur(today) + " of " + Stats.dur(goal);
        SpannableStringBuilder sb = new SpannableStringBuilder(a);
        sb.setSpan(new ForegroundColorSpan(Charts.alpha(Charts.status(today, goal), 0xCC)), 0, a.length(),
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        int ex = Stats.examDays(p);
        if (ex >= 0) {
            String b = "   \u00B7   " + (ex == 0 ? "Exam day" : "Exam in " + ex + (ex == 1 ? " day" : " days"));
            int start = sb.length();
            sb.append(b);
            sb.setSpan(new ForegroundColorSpan(0xCC8C93A3), start, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        info.setText(sb);
    }

    private int dp(float v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private TextView button(String label, View.OnClickListener l) {
        TextView t = new TextView(this);
        t.setText(label);
        t.setTextSize(15f);
        t.setTextColor(0xFFE6E9F0);
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(14), dp(12), dp(14), dp(12));
        t.setOnClickListener(v -> {
            l.onClick(v);
            if (bar.getVisibility() == View.VISIBLE) {
                handler.removeCallbacks(hideBar);
                handler.postDelayed(hideBar, 4000L);
            }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        t.setLayoutParams(lp);
        return t;
    }

    private void bright(int d) {
        level = Math.max(0, Math.min(LEVELS.length - 1, level + d));
        applyBrightness();
    }

    private void applyBrightness() {
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = LEVELS[level];
        getWindow().setAttributes(lp);
    }

    private void command(String action) {
        Intent i = new Intent(this, FloatingService.class);
        i.setAction(action);
        startService(i);
    }

    private void immersive() {
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    @Override
    protected void onStart() {
        super.onStart();
        Intent i = new Intent(this, FloatingService.class);
        i.setAction(FloatingService.ACTION_DESK_ON);
        if (FloatingService.active) {
            startService(i);
        } else {
            startForegroundService(i);
        }
        immersive();
        bv.applyPrefs(p);
        fit();
        updateInfo();
        infoAt = System.currentTimeMillis();
        hint.setText(FloatingService.dClock ? "Tap anywhere for buttons"
                : "Tap the clock to pause  \u00B7  Hold to restart  \u00B7  Tap the empty space for buttons");
        hint.setVisibility(View.VISIBLE);
        handler.removeCallbacks(hideHint);
        handler.postDelayed(hideHint, 6000L);
        handler.post(poll);
    }

    @Override
    protected void onStop() {
        handler.removeCallbacks(poll);
        handler.removeCallbacks(hideBar);
        handler.removeCallbacks(hideHint);
        if (FloatingService.active) command(FloatingService.ACTION_DESK_OFF);
        super.onStop();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) immersive();
    }

    @Override
    public void onConfigurationChanged(Configuration c) {
        super.onConfigurationChanged(c);
        fit();
    }

    /** Make the clock as large as the screen allows. */
    private void fit() {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        float wDp = dm.widthPixels / dm.density;
        float hDp = dm.heightPixels / dm.density;
        boolean pill = Prefs.getInt(p, Prefs.SHAPE) == Prefs.SHAPE_PILL;
        float wf = pill ? 1.7f : 1f;
        float hf = pill ? 0.7f : 1f;
        float s = Math.min(hDp * 0.72f / hf, wDp * 0.88f / wf);
        bv.sizeDp = Math.round(Math.min(s, 900f));
        bv.requestLayout();
        bv.invalidate();
    }

    private void show() {
        long nowMs = System.currentTimeMillis();
        if (nowMs - infoAt > 5000L) {
            infoAt = nowMs;
            updateInfo();
        }
        if (!FloatingService.active) {
            bv.setPaused(false);
            bv.setState("--:--", null, -1f, 0, false);
            return;
        }
        boolean clock = FloatingService.dClock;
        resetBtn.setVisibility(clock ? View.GONE : View.VISIBLE);
        toggleBtn.setVisibility(clock ? View.GONE : View.VISIBLE);
        skipBtn.setVisibility(FloatingService.dBreak ? View.VISIBLE : View.GONE);
        toggleBtn.setText(FloatingService.dPaused || FloatingService.dLabel != null
                && FloatingService.dLabel.startsWith("TAP") ? "Start" : "Pause");
        bv.setPaused(FloatingService.dPaused);
        int face = FloatingService.dFace;
        if (face >= 0) {
            bv.setDial(face, FloatingService.dKind, FloatingService.dProg, FloatingService.dHour,
                    FloatingService.dMin, FloatingService.dSecA, FloatingService.dSecHand,
                    FloatingService.dText, FloatingService.dLabel, FloatingService.dRing, FloatingService.dHl);
        } else {
            bv.setState(FloatingService.dText, FloatingService.dLabel, FloatingService.dProg,
                    FloatingService.dRing, FloatingService.dHl);
        }
        if (Prefs.getInt(p, Prefs.DESK_MOVE) == 1) {
            long step = System.currentTimeMillis() / 60000L;
            if (step != moveStep) {
                moveStep = step;
                float[][] spots = {{0, 0}, {-1, -0.6f}, {1, 0.5f}, {-0.6f, 1}, {0.7f, -1}, {1, 1}, {-1, 0.2f}};
                float[] sp = spots[(int) (step % spots.length)];
                float rx = Math.max(0f, root.getWidth() - bv.getWidth()) / 2f * 0.9f;
                float ry = Math.max(0f, root.getHeight() - bv.getHeight()) / 2f * 0.9f;
                bv.animate().translationX(sp[0] * rx).translationY(sp[1] * ry).setDuration(2500L).start();
                info.animate().translationX(sp[0] * rx * 0.5f).setDuration(2500L).start();
            }
        }
    }
}
FLOATY_EOF
cat > 'app/src/main/res/drawable/ic_desk.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M5,4 h14 a2,2 0 0 1 2,2 v9 a2,2 0 0 1 -2,2 h-14 a2,2 0 0 1 -2,-2 v-9 a2,2 0 0 1 2,-2 z M9,21 h6 M12,17 v4 M12,7 v3.2 l2.2,1.4"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/ReportCard.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;

import java.text.SimpleDateFormat;
import java.util.Locale;

/** Draws the shareable report card picture. */
final class ReportCard {
    private static final int BG = 0xFF101319;
    private static final int SURFACE = 0xFF171C25;
    private static final int PANEL = 0xFF1D2330;
    private static final int TEXT = 0xFFE6E9F0;
    private static final int MUTED = 0xFF8C93A3;
    private static final int PILL = 0xFF2A3140;

    private ReportCard() {
    }

    private static Typeface reg() {
        return Typeface.create("sans-serif", Typeface.NORMAL);
    }

    private static Typeface med() {
        return Typeface.create("sans-serif-medium", Typeface.NORMAL);
    }

    private static void text(Canvas c, Paint p, String s, float x, float y, float size, int color, boolean bold,
                             Paint.Align align) {
        p.setStyle(Paint.Style.FILL);
        p.setShader(null);
        p.setTypeface(bold ? med() : reg());
        p.setTextSize(size);
        p.setColor(color);
        p.setTextAlign(align);
        c.drawText(s, x, y, p);
    }

    private static void roundRect(Canvas c, Paint p, float l, float t, float r, float b, float rad, int color) {
        p.setStyle(Paint.Style.FILL);
        p.setShader(null);
        p.setColor(color);
        c.drawRoundRect(new RectF(l, t, r, b), rad, rad, p);
    }

    /** examDays: days until the exam, 0 on exam day, -1 when there is no date. */
    static Bitmap render(int goalSec, int todaySec, int streak, int stars, int run, int thisWeek,
                         int lastWeek, int[] last14, int examDays) {
        int W = 1080;
        int H = 1350;
        Bitmap bmp = Bitmap.createBitmap(W, H, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(bmp);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        c.drawColor(BG);
        roundRect(c, p, 40, 40, W - 40, H - 40, 48, SURFACE);

        int pct = Stats.weekPct(thisWeek, lastWeek);
        int tcol = Charts.trend(pct);

        // header
        text(c, p, "Watchu", 100, 142, 58, TEXT, true, Paint.Align.LEFT);
        String range;
        try {
            SimpleDateFormat f = new SimpleDateFormat("d MMM", Locale.getDefault());
            range = f.format(Stats.cal(-6).getTime()) + " – " + f.format(Stats.cal(0).getTime());
        } catch (Exception e) {
            range = "";
        }
        text(c, p, "Report card · " + range, 100, 192, 32, MUTED, false, Paint.Align.LEFT);

        // exam chip, coloured by the 7-day average against the goal
        if (examDays >= 0) {
            int ecol = Charts.status(thisWeek / 7, goalSec);
            String et = examDays == 0 ? "EXAM DAY" : "EXAM IN " + examDays + (examDays == 1 ? " DAY" : " DAYS");
            p.setTypeface(med());
            p.setTextSize(28);
            float tw = p.measureText(et);
            float cw = tw + 56;
            roundRect(c, p, 1020 - cw, 70, 1020, 132, 31, Charts.alpha(ecol, 0x33));
            text(c, p, et, 1020 - cw / 2f, 111, 28, ecol, true, Paint.Align.CENTER);
        }

        // ring: red below half of the goal, amber from half, green when the goal is met
        float frac = goalSec > 0 ? Math.min(1f, todaySec / (float) goalSec) : 0f;
        Charts.ring(c, 540, 370, 130, 28, frac, Charts.status(todaySec, goalSec), 0x33FFFFFF);
        text(c, p, Stats.dur(todaySec), 540, 368, 52, TEXT, true, Paint.Align.CENTER);
        text(c, p, "of " + Stats.dur(goalSec) + " today", 540, 406, 27, MUTED, false, Paint.Align.CENTER);

        // this week against last week
        roundRect(c, p, 80, 548, 1000, 763, 36, PANEL);
        text(c, p, "THIS WEEK vs LAST WEEK", 110, 600, 24, MUTED, true, Paint.Align.LEFT);
        float bx = 110;
        if (pct != Stats.NO_PCT && pct != 0) {
            Path tri = new Path();
            float ty = 678;
            if (pct > 0) {
                tri.moveTo(bx, ty + 26);
                tri.lineTo(bx + 56, ty + 26);
                tri.lineTo(bx + 28, ty - 26);
            } else {
                tri.moveTo(bx, ty - 26);
                tri.lineTo(bx + 56, ty - 26);
                tri.lineTo(bx + 28, ty + 26);
            }
            tri.close();
            p.setStyle(Paint.Style.FILL);
            p.setColor(tcol);
            c.drawPath(tri, p);
            bx += 80;
        }
        String pt = Stats.pctText(pct);
        float size = 96;
        p.setTypeface(med());
        p.setTextSize(size);
        float maxW = 480 - (bx - 110);
        float w = p.measureText(pt);
        if (w > maxW) size = size * maxW / w;
        text(c, p, pt, bx, 703, size, tcol, true, Paint.Align.LEFT);

        String[] k = {"This week", "Last week"};
        String[] v = {Stats.dur(thisWeek), Stats.dur(lastWeek)};
        float[] ys = {664, 712};
        for (int i = 0; i < 2; i++) {
            p.setTypeface(med());
            p.setTextSize(36);
            float vw = p.measureText(v[i]);
            text(c, p, v[i], 970, ys[i], 36, TEXT, true, Paint.Align.RIGHT);
            text(c, p, k[i], 970 - vw - 18, ys[i], 28, MUTED, false, Paint.Align.RIGHT);
        }

        // last 14 days, stock style
        roundRect(c, p, 80, 783, 1000, 1101, 36, PANEL);
        text(c, p, "LAST 14 DAYS", 110, 832, 24, MUTED, true, Paint.Align.LEFT);
        String tw2 = Stats.trendWord(pct);
        p.setTypeface(med());
        p.setTextSize(28);
        float pw = p.measureText(tw2) + 48;
        roundRect(c, p, 964 - pw, 797, 964, 851, 27, Charts.alpha(tcol, 0x33));
        text(c, p, tw2, 964 - pw / 2f, 834, 28, tcol, true, Paint.Align.CENTER);

        Charts.Style st = new Charts.Style();
        st.fs = 24;
        st.dot = 7;
        st.line = 6;
        st.axis = true;
        st.tag = true;
        st.goalLabel = true;
        st.valueLine = true;
        st.labels = Stats.dayLabels(last14.length, 2);
        st.surface = PANEL;
        st.textColor = MUTED;
        st.textStrong = TEXT;
        Charts.stock(c, 80, 862, 920, 240, last14, goalSec, st);

        // legend
        String[] ln = {"Goal met", "Half or more", "Under half"};
        int[] lc = {Charts.GREEN, Charts.AMBER, Charts.RED};
        float lx = 110;
        for (int i = 0; i < 3; i++) {
            p.setStyle(Paint.Style.FILL);
            p.setColor(lc[i]);
            c.drawCircle(lx + 8, 1140, 8, p);
            p.setTypeface(reg());
            p.setTextSize(24);
            text(c, p, ln[i], lx + 26, 1148, 24, MUTED, false, Paint.Align.LEFT);
            lx += 26 + p.measureText(ln[i]) + 40;
        }

        // streak and stars
        String s1 = "Streak  " + streak + (streak == 1 ? " day" : " days");
        String s2 = "Stars  " + stars + "  (" + run + "/10)";
        p.setTypeface(med());
        p.setTextSize(28);
        float w1 = p.measureText(s1) + 56;
        float w2 = p.measureText(s2) + 56;
        float gap = 24;
        float sx = 540 - (w1 + w2 + gap) / 2f;
        roundRect(c, p, sx, 1172, sx + w1, 1226, 27, PILL);
        text(c, p, s1, sx + w1 / 2f, 1209, 28, TEXT, true, Paint.Align.CENTER);
        roundRect(c, p, sx + w1 + gap, 1172, sx + w1 + gap + w2, 1226, 27, PILL);
        text(c, p, s2, sx + w1 + gap + w2 / 2f, 1209, 28, TEXT, true, Paint.Align.CENTER);

        text(c, p, "Made with Watchu. Free for life.", 540, 1275, 28, MUTED, false, Paint.Align.CENTER);
        return bmp;
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/RingView.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.view.View;

/** A progress ring with a big and a small line of text in the middle. */
final class RingView extends View {
    float frac = 0f;
    int trackColor = 0x33FFFFFF;
    int arcColor = 0xFFA9C5FF;
    int textColor = 0xFFFFFFFF;
    int subColor = 0xFF8C93A3;
    String big = "";
    String small = "";
    private final Paint pt = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rf = new RectF();

    RingView(Context c) {
        super(c);
        pt.setTextAlign(Paint.Align.CENTER);
    }

    @Override
    protected void onDraw(Canvas c) {
        float w = getWidth();
        float h = getHeight();
        float s = Math.min(w, h);
        float sw = s * 0.09f;
        float cx = w / 2f;
        float cy = h / 2f;
        rf.set(cx - s / 2f + sw, cy - s / 2f + sw, cx + s / 2f - sw, cy + s / 2f - sw);
        pt.setStyle(Paint.Style.STROKE);
        pt.setStrokeWidth(sw);
        pt.setStrokeCap(Paint.Cap.ROUND);
        pt.setColor(trackColor);
        c.drawOval(rf, pt);
        if (frac > 0.003f) {
            pt.setColor(arcColor);
            c.drawArc(rf, -90f, 360f * Math.min(1f, frac), false, pt);
        }
        pt.setStyle(Paint.Style.FILL);
        pt.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        pt.setColor(textColor);
        float ts = s * 0.20f;
        pt.setTextSize(ts);
        float tw = pt.measureText(big);
        float maxw = s * 0.62f;
        if (tw > maxw) {
            ts = ts * maxw / tw;
            pt.setTextSize(ts);
        }
        c.drawText(big, cx, cy + ts * 0.15f, pt);
        pt.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        pt.setColor(subColor);
        pt.setTextSize(s * 0.085f);
        c.drawText(small, cx, cy + ts * 0.15f + s * 0.14f, pt);
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/Stats.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.SharedPreferences;

import java.util.Calendar;
import java.util.Map;
import java.util.TreeMap;

/** Time spent on timers, one total per day, kept on this device only. */
final class Stats {
    static final String DATA = "stats_data";

    private Stats() {
    }

    static int key(Calendar c) {
        return c.get(Calendar.YEAR) * 10000 + (c.get(Calendar.MONTH) + 1) * 100 + c.get(Calendar.DAY_OF_MONTH);
    }

    static Calendar cal(int offsetDays) {
        Calendar c = Calendar.getInstance();
        c.add(Calendar.DAY_OF_MONTH, offsetDays);
        return c;
    }

    static Calendar fromKey(int k) {
        Calendar c = Calendar.getInstance();
        c.set(k / 10000, (k / 100) % 100 - 1, k % 100, 12, 0, 0);
        return c;
    }

    static TreeMap<Integer, Integer> load(SharedPreferences p) {
        TreeMap<Integer, Integer> m = new TreeMap<Integer, Integer>();
        String raw = p.getString(DATA, "");
        if (raw == null || raw.length() == 0) return m;
        for (String part : raw.split(",")) {
            int i = part.indexOf(':');
            if (i < 1) continue;
            try {
                m.put(Integer.parseInt(part.substring(0, i)), Integer.parseInt(part.substring(i + 1)));
            } catch (NumberFormatException ignored) {
            }
        }
        return m;
    }

    private static void save(SharedPreferences p, TreeMap<Integer, Integer> m) {
        while (m.size() > 400) m.remove(m.firstKey());
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<Integer, Integer> e : m.entrySet()) {
            if (sb.length() > 0) sb.append(',');
            sb.append(e.getKey()).append(':').append(e.getValue());
        }
        p.edit().putString(DATA, sb.toString()).apply();
    }

    /** Adds whole seconds to today's total. */
    static void addSeconds(SharedPreferences p, int sec) {
        if (sec <= 0) return;
        TreeMap<Integer, Integer> m = load(p);
        int k = key(Calendar.getInstance());
        Integer old = m.get(k);
        m.put(k, (old == null ? 0 : old) + sec);
        save(p, m);
    }

    static int secs(Map<Integer, Integer> m, Calendar c) {
        Integer v = m.get(key(c));
        return v == null ? 0 : v;
    }

    static int sumDays(Map<Integer, Integer> m, int fromOffset, int toOffset) {
        int t = 0;
        for (int o = fromOffset; o <= toOffset; o++) t += secs(m, cal(o));
        return t;
    }

    static int streak(Map<Integer, Integer> m, int goalSec) {
        int s = 0;
        Calendar c = cal(0);
        if (secs(m, c) < goalSec) c.add(Calendar.DAY_OF_MONTH, -1);
        while (secs(m, c) >= goalSec && goalSec > 0 && s < 400) {
            s++;
            c.add(Calendar.DAY_OF_MONTH, -1);
        }
        return s;
    }

    /** Counts finished days toward stars: 10 days in a row on goal earns one star. A miss restarts the 10. */
    static void evaluate(SharedPreferences p) {
        int yk = key(cal(-1));
        int last = p.getInt(Prefs.LAST_EVAL, 0);
        if (last == 0) {
            p.edit().putInt(Prefs.LAST_EVAL, yk).apply();
            return;
        }
        if (last >= yk) return;
        int goal = Prefs.getInt(p, Prefs.GOAL_MIN) * 60;
        TreeMap<Integer, Integer> m = load(p);
        int stars = Prefs.getInt(p, Prefs.STARS);
        int run = Prefs.getInt(p, Prefs.STAR_RUN);
        Calendar c = fromKey(last);
        c.add(Calendar.DAY_OF_MONTH, 1);
        int guard = 0;
        while (key(c) <= yk && guard++ < 800) {
            if (secs(m, c) >= goal) {
                run++;
                if (run >= 10) {
                    stars++;
                    run = 0;
                }
            } else {
                run = 0;
            }
            c.add(Calendar.DAY_OF_MONTH, 1);
        }
        p.edit().putInt(Prefs.STARS, stars).putInt(Prefs.STAR_RUN, run).putInt(Prefs.LAST_EVAL, yk).apply();
    }

    /** New goal: stars start again from today. */
    static void setGoal(SharedPreferences p, int minutes) {
        p.edit().putInt(Prefs.GOAL_MIN, minutes).putInt(Prefs.STARS, 0).putInt(Prefs.STAR_RUN, 0)
                .putInt(Prefs.LAST_EVAL, key(cal(-1))).apply();
    }

    /** Days until the exam: 0 on exam day, -1 when no date is set or it has passed. */
    static int examDays(SharedPreferences p) {
        int ek = p.getInt(Prefs.EXAM_DATE, 0);
        if (ek == 0) return -1;
        Calendar a = Calendar.getInstance();
        a.set(Calendar.HOUR_OF_DAY, 12);
        Calendar b = fromKey(ek);
        long days = Math.round((b.getTimeInMillis() - a.getTimeInMillis()) / 86400000.0);
        return days < 0 ? -1 : (int) days;
    }

    /** No comparison possible: last week had nothing. */
    static final int NO_PCT = Integer.MIN_VALUE;

    /** Change from last week to this week, in whole percent. */
    static int weekPct(int thisWeek, int lastWeek) {
        if (lastWeek <= 0) return NO_PCT;
        return Math.round((thisWeek - lastWeek) * 100f / lastWeek);
    }

    static String pctText(int pct) {
        if (pct == NO_PCT) return "New";
        return (pct > 0 ? "+" : "") + pct + "%";
    }

    /** Words for the week-on-week change, with an arrow. */
    static String trendWord(int pct) {
        if (pct == NO_PCT) return "New";
        if (pct >= 5) return "\u25B2 Rising";
        if (pct <= -5) return "\u25BC Falling";
        return "Steady";
    }

    /** Seconds for each of the last n days, oldest first, ending today. */
    static int[] lastDays(Map<Integer, Integer> m, int n) {
        int[] a = new int[n];
        for (int i = 0; i < n; i++) a[i] = secs(m, cal(i - (n - 1)));
        return a;
    }

    /** Short weekday names for the last n days, oldest first. Only every step-th day (counting back from today) gets one. */
    static String[] dayLabels(int n, int step) {
        String[] a = new String[n];
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault());
        for (int i = 0; i < n; i++) {
            if ((n - 1 - i) % step == 0) a[i] = f.format(cal(i - (n - 1)).getTime());
        }
        return a;
    }

    /** Compact duration, like 2h 30m, 42m or 3h. */
    static String durShort(int sec) {
        int m = Math.round(sec / 60f);
        int h = m / 60;
        int r = m % 60;
        if (h == 0) return r + "m";
        if (r == 0) return h + "h";
        return h + "h " + r + "m";
    }

    static String dur(int sec) {
        int m = Math.round(sec / 60f);
        int h = m / 60;
        int r = m % 60;
        if (h == 0) return r + " m";
        if (r == 0) return h + " h";
        return h + " h " + r + " m";
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/QuickStartActivity.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

/** Invisible activity behind the app-icon shortcuts: applies a choice and starts the bubble. */
public class QuickStartActivity extends Activity {
    static final String EXTRA = "which";

    static List<Presets.Preset> visiblePresets(SharedPreferences p) {
        List<Presets.Preset> out = new ArrayList<Presets.Preset>();
        List<String> hidden = Presets.hidden(p);
        for (Presets.Preset x : Presets.builtIns()) {
            if (!hidden.contains(x.name)) out.add(x);
        }
        out.addAll(Presets.saved(p));
        return out;
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        SharedPreferences p = Prefs.get(this);
        String which = getIntent().getStringExtra(EXTRA);
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "Allow \"Display over other apps\" for Watchu first.", Toast.LENGTH_LONG).show();
            startActivity(new Intent(this, MainActivity.class));
            finish();
            return;
        }
        if ("desk".equals(which)) {
            startActivity(new Intent(this, DeskActivity.class));
            finish();
            return;
        }
        boolean go = false;
        if ("stopwatch".equals(which)) {
            p.edit().putInt(Prefs.MODE, Prefs.MODE_STOPWATCH).apply();
            go = true;
        } else if (which != null && which.startsWith("p")) {
            try {
                int i = Integer.parseInt(which.substring(1));
                List<Presets.Preset> list = visiblePresets(p);
                if (i >= 0 && i < list.size()) {
                    Presets.apply(p, list.get(i));
                    go = true;
                }
            } catch (NumberFormatException ignored) {
            }
        }
        if (go) {
            Intent s = new Intent(this, FloatingService.class);
            s.setAction(FloatingService.ACTION_QUICK);
            if (FloatingService.active) {
                startService(s);
            } else {
                startForegroundService(s);
            }
        }
        finish();
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/Charts.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.graphics.Canvas;
import android.graphics.DashPathEffect;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;

/**
 * Shared drawing and colour rules, so the Stats page, the report card and the widget always match.
 * Colours: green = goal met, amber = half of the goal or more, red = under half.
 */
final class Charts {
    static final int GREEN = 0xFF3DDC97;
    static final int AMBER = 0xFFFFB547;
    static final int RED = 0xFFFF6B73;
    static final int BLUE = 0xFF9FB4E8;
    static final int MUTED = 0xFF8C93A3;

    private Charts() {
    }

    /** Status colour of an amount against the goal. */
    static int status(int sec, int goalSec) {
        if (goalSec <= 0) return BLUE;
        if (sec >= goalSec) return GREEN;
        if (sec * 2 >= goalSec) return AMBER;
        return RED;
    }

    /** Colour of the week-on-week change: green up 5% or more, red down 5% or more, otherwise blue. */
    static int trend(int pct) {
        if (pct == Stats.NO_PCT) return BLUE;
        if (pct >= 5) return GREEN;
        if (pct <= -5) return RED;
        return BLUE;
    }

    static int alpha(int color, int a) {
        return (color & 0x00FFFFFF) | (a << 24);
    }

    /** Settings for {@link #stock}. Sizes are in pixels. */
    static final class Style {
        float fs = 12f;
        float dot = 4f;
        float line = 3f;
        /** Value labels on the left with faint dashed grid lines. */
        boolean axis = false;
        /** Bubble with the latest value above the last dot. */
        boolean tag = false;
        /** Small "goal 6h" text on the goal line. */
        boolean goalLabel = false;
        /** Colour the line by value: red low, amber around half the goal, green at the goal. */
        boolean valueLine = true;
        /** Labels under the graph, one per point (null entries are skipped). */
        String[] labels = null;
        int lineColor = BLUE;
        int surface = 0xFF171C25;
        int textColor = MUTED;
        int textStrong = 0xFFE6E9F0;
    }

    private static void smooth(Path p, float[] x, float[] y) {
        // monotone cubic: the line never dips below a flat stretch or overshoots a peak
        int n = x.length;
        float[] d = new float[n - 1];
        float[] m = new float[n];
        for (int i = 0; i < n - 1; i++) d[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i]);
        m[0] = d[0];
        m[n - 1] = d[n - 2];
        for (int i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0f ? 0f : (d[i - 1] + d[i]) / 2f;
        for (int i = 0; i < n - 1; i++) {
            if (d[i] == 0f) {
                m[i] = 0f;
                m[i + 1] = 0f;
            } else {
                float a = m[i] / d[i];
                float b = m[i + 1] / d[i];
                float s = a * a + b * b;
                if (s > 9f) {
                    float t = 3f / (float) Math.sqrt(s);
                    m[i] = t * a * d[i];
                    m[i + 1] = t * b * d[i];
                }
            }
        }
        p.moveTo(x[0], y[0]);
        for (int i = 0; i < n - 1; i++) {
            float h = x[i + 1] - x[i];
            p.cubicTo(x[i] + h / 3f, y[i] + m[i] * h / 3f, x[i + 1] - h / 3f, y[i + 1] - m[i + 1] * h / 3f,
                    x[i + 1], y[i + 1]);
        }
    }

    /** A tick step (in seconds) that gives about four readable grid lines. */
    private static int tickStep(float maxSec) {
        int[] mins = {10, 15, 20, 30, 60, 90, 120, 180, 240, 360, 480, 720, 1440};
        for (int m : mins) {
            if (maxSec / (m * 60f) <= 4.2f) return m * 60;
        }
        return 1440 * 60;
    }

    /**
     * A stock-chart style line graph: smooth line coloured by value, shaded area, dashed goal level,
     * a dot per day, optional value labels, a latest-value bubble and day labels.
     */
    static void stock(Canvas c, float left, float top, float w, float h, int[] secs, int goalSec, Style s) {
        int n = secs.length;
        if (n < 2 || w <= 0f || h <= 0f) return;
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));

        float maxV = Math.max(goalSec, 1);
        for (int v : secs) if (v > maxV) maxV = v;
        float hi = maxV * 1.12f;
        int step = tickStep(hi);

        float padL = s.fs * 0.6f;
        if (s.axis) {
            p.setTextSize(s.fs);
            float widest = p.measureText("0m");
            for (int t = step; t <= hi; t += step) widest = Math.max(widest, p.measureText(Stats.durShort(t)));
            padL = widest + s.fs * 1.1f;
        }
        float padR = s.tag ? s.fs * 2.4f : s.fs * 1.0f;
        float padT = Math.max(s.dot * 2.6f, s.fs * 0.6f);
        float padB = padT + (s.labels != null ? s.fs * 1.9f : 0f);
        float x0 = left + padL;
        float gw = w - padL - padR;
        float yTop = top + padT;
        float yBase = top + h - padB;
        if (gw <= 4f || yBase <= yTop + 4f) return;
        float span = hi;

        float[] xs = new float[n];
        float[] ys = new float[n];
        for (int i = 0; i < n; i++) {
            xs[i] = x0 + i * (gw / (n - 1));
            ys[i] = yBase - (secs[i] / span) * (yBase - yTop);
        }
        float yGoal = yBase - (goalSec / span) * (yBase - yTop);

        // grid and value labels
        if (s.axis) {
            for (int t = 0; t <= hi; t += step) {
                float yy = yBase - (t / span) * (yBase - yTop);
                if (t > 0 && Math.abs(yy - yGoal) < s.fs * 0.6f) {
                    // the goal line already marks this level
                } else if (t > 0) {
                    p.setStyle(Paint.Style.STROKE);
                    p.setStrokeWidth(Math.max(1f, s.fs / 12f));
                    p.setColor(0x16FFFFFF);
                    p.setPathEffect(new DashPathEffect(new float[]{s.fs * 0.35f, s.fs * 0.35f}, 0f));
                    c.drawLine(x0, yy, x0 + gw, yy, p);
                    p.setPathEffect(null);
                }
                p.setStyle(Paint.Style.FILL);
                p.setColor(alpha(s.textColor, 0xC8));
                p.setTextSize(s.fs);
                p.setTextAlign(Paint.Align.LEFT);
                c.drawText(t == 0 ? "0m" : Stats.durShort(t), left + s.fs * 0.3f, yy + s.fs * 0.35f, p);
            }
        }

        Path line = new Path();
        smooth(line, xs, ys);
        Path area = new Path(line);
        area.lineTo(xs[n - 1], yBase);
        area.lineTo(xs[0], yBase);
        area.close();

        boolean vl = s.valueLine && goalSec > 0;
        Shader fillShader;
        Shader lineShader = null;
        if (vl) {
            fillShader = new LinearGradient(0f, yGoal, 0f, yBase,
                    new int[]{alpha(GREEN, 0x66), alpha(AMBER, 0x40), alpha(RED, 0x12)},
                    new float[]{0f, 0.5f, 1f}, Shader.TileMode.CLAMP);
            lineShader = new LinearGradient(0f, yGoal, 0f, yBase, new int[]{GREEN, AMBER, RED},
                    new float[]{0f, 0.5f, 1f}, Shader.TileMode.CLAMP);
        } else {
            fillShader = new LinearGradient(0f, yTop, 0f, yBase, alpha(s.lineColor, 0x60), alpha(s.lineColor, 0x00),
                    Shader.TileMode.CLAMP);
        }
        p.setStyle(Paint.Style.FILL);
        p.setShader(fillShader);
        c.drawPath(area, p);
        p.setShader(null);

        // goal level
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(Math.max(1f, s.fs / 9f));
        p.setColor(0xB0C7CCD8);
        p.setPathEffect(new DashPathEffect(new float[]{s.fs * 0.7f, s.fs * 0.5f}, 0f));
        c.drawLine(x0, yGoal, x0 + gw, yGoal, p);
        p.setPathEffect(null);
        if (s.goalLabel) {
            p.setStyle(Paint.Style.FILL);
            p.setColor(0xCCC7CCD8);
            p.setTextSize(s.fs * 0.95f);
            p.setTextAlign(Paint.Align.LEFT);
            c.drawText("goal " + Stats.durShort(goalSec), x0 + s.fs * 0.4f, yGoal - s.fs * 0.45f, p);
        }

        // the line
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(s.line);
        p.setStrokeCap(Paint.Cap.ROUND);
        p.setStrokeJoin(Paint.Join.ROUND);
        if (vl) {
            p.setShader(lineShader);
        } else {
            p.setColor(s.lineColor);
        }
        c.drawPath(line, p);
        p.setShader(null);

        // dots, and the last one with a glow
        int lastCol = status(secs[n - 1], goalSec);
        p.setStyle(Paint.Style.FILL);
        for (int i = 0; i < n - 1; i++) {
            p.setColor(status(secs[i], goalSec));
            c.drawCircle(xs[i], ys[i], s.dot, p);
        }
        p.setColor(alpha(lastCol, 0x48));
        c.drawCircle(xs[n - 1], ys[n - 1], s.dot * 3.0f, p);
        p.setColor(lastCol);
        c.drawCircle(xs[n - 1], ys[n - 1], s.dot * 1.9f, p);
        p.setColor(0xFFFFFFFF);
        c.drawCircle(xs[n - 1], ys[n - 1], s.dot * 1.05f, p);

        // bubble with the latest value
        if (s.tag) {
            String t = Stats.durShort(secs[n - 1]);
            p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            p.setTextSize(s.fs * 1.05f);
            float bw = p.measureText(t) + s.fs * 1.3f;
            float bh = s.fs * 2.0f;
            float by = ys[n - 1] - s.dot * 3.2f - bh;
            if (by < top) by = ys[n - 1] + s.dot * 3.2f;
            float bx = Math.min(xs[n - 1] + bw / 2f, left + w);
            RectF r = new RectF(bx - bw, by, bx, by + bh);
            p.setColor(lastCol);
            c.drawRoundRect(r, bh * 0.38f, bh * 0.38f, p);
            p.setColor(0xFF101319);
            p.setTextAlign(Paint.Align.CENTER);
            c.drawText(t, r.centerX(), r.centerY() + s.fs * 0.38f, p);
            p.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        }

        // day labels
        if (s.labels != null) {
            p.setStyle(Paint.Style.FILL);
            p.setTextSize(s.fs);
            p.setTextAlign(Paint.Align.CENTER);
            float ly = yBase + s.fs * 1.9f - s.fs * 0.1f;
            for (int i = 0; i < n && i < s.labels.length; i++) {
                if (s.labels[i] == null) continue;
                p.setColor(i == n - 1 ? s.textStrong : alpha(s.textColor, 0xE0));
                c.drawText(s.labels[i], xs[i], ly, p);
            }
        }
    }

    /** A progress ring. */
    static void ring(Canvas c, float cx, float cy, float r, float stroke, float frac, int color, int track) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(stroke);
        p.setStrokeCap(Paint.Cap.ROUND);
        RectF rf = new RectF(cx - r, cy - r, cx + r, cy + r);
        if (frac > 0.003f) {
            // soft glow in the same colour
            p.setColor(alpha(color, 0x30));
            p.setStrokeWidth(stroke * 1.5f);
            c.drawArc(rf, -90f, 360f * Math.min(1f, frac), false, p);
            p.setStrokeWidth(stroke);
        }
        p.setColor(track);
        c.drawOval(rf, p);
        if (frac > 0.003f) {
            p.setColor(color);
            c.drawArc(rf, -90f, 360f * Math.min(1f, frac), false, p);
        }
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/QuickTileService.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.PendingIntent;
import android.content.Intent;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import java.util.List;

/**
 * Quick Settings tile. Tap starts your first preset, tap while running pauses or resumes,
 * long-press opens the app.
 */
public class QuickTileService extends TileService {
    private final Handler handler = new Handler(Looper.getMainLooper());

    @Override
    public void onStartListening() {
        super.onStartListening();
        update();
    }

    @Override
    public void onClick() {
        super.onClick();
        if (FloatingService.active && !FloatingService.dClock) {
            Intent t = new Intent(this, FloatingService.class);
            t.setAction(FloatingService.ACTION_TOGGLE);
            try {
                startService(t);
            } catch (Exception ignored) {
            }
            handler.postDelayed(this::update, 400L);
            return;
        }
        Intent i = new Intent(this, QuickStartActivity.class);
        i.putExtra(QuickStartActivity.EXTRA, "p0");
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                PendingIntent pi = PendingIntent.getActivity(this, 200, i,
                        PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
                startActivityAndCollapse(pi);
            } else {
                startActivityAndCollapse(i);
            }
        } catch (Exception ignored) {
        }
    }

    private void update() {
        Tile t = getQsTile();
        if (t == null) return;
        boolean on = FloatingService.active && !FloatingService.dClock;
        t.setState(on ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        t.setLabel(getString(R.string.app_name));
        t.setIcon(Icon.createWithResource(this, R.drawable.ic_tile));
        if (Build.VERSION.SDK_INT >= 29) {
            String sub;
            if (on) {
                sub = (FloatingService.dPaused ? "Paused " : "") + FloatingService.dText;
            } else {
                List<Presets.Preset> list = QuickStartActivity.visiblePresets(Prefs.get(this));
                sub = list.isEmpty() ? "Tap to open" : "Start " + list.get(0).name;
            }
            t.setSubtitle(sub);
        }
        t.updateTile();
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/StockView.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.content.Context;
import android.graphics.Canvas;
import android.view.View;

/** The stock-style graph of recent days: line coloured by value, goal line, value labels and day names. */
final class StockView extends View {
    int[] secs = new int[14];
    int goalSec = 3600;
    int surface = 0xFF171C25;
    int textColor = Charts.MUTED;
    int textStrong = 0xFFE6E9F0;

    StockView(Context c) {
        super(c);
    }

    @Override
    protected void onDraw(Canvas c) {
        float d = getResources().getDisplayMetrics().density;
        Charts.Style st = new Charts.Style();
        st.fs = 11f * d;
        st.dot = 3.2f * d;
        st.line = 2.8f * d;
        st.axis = true;
        st.tag = true;
        st.goalLabel = true;
        st.valueLine = true;
        st.labels = Stats.dayLabels(secs.length, 2);
        st.surface = surface;
        st.textColor = textColor;
        st.textStrong = textStrong;
        Charts.stock(c, 0f, 0f, getWidth(), getHeight(), secs, goalSec, st);
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/WatchuWidget.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.View;
import android.widget.RemoteViews;

import java.util.List;
import java.util.Map;

/**
 * The home-screen widget: today's ring, the weekly change, a small stock-style graph, the exam countdown
 * and three quick-start buttons. It refreshes when the app opens, when a session ends and every ~30 minutes.
 */
public class WatchuWidget extends AppWidgetProvider {
    private static final int SURFACE = 0xFF171C25;
    private static final int TEXT = 0xFFE6E9F0;
    private static final int MUTED = 0xFF8C93A3;

    @Override
    public void onUpdate(Context ctx, AppWidgetManager mgr, int[] ids) {
        for (int id : ids) push(ctx, mgr, id);
    }

    @Override
    public void onAppWidgetOptionsChanged(Context ctx, AppWidgetManager mgr, int id, Bundle newOptions) {
        push(ctx, mgr, id);
    }

    /** Redraws every Watchu widget on the home screen. Safe to call when there are none. */
    static void refresh(Context ctx) {
        try {
            Context app = ctx.getApplicationContext();
            AppWidgetManager mgr = AppWidgetManager.getInstance(app);
            int[] ids = mgr.getAppWidgetIds(new ComponentName(app, WatchuWidget.class));
            for (int id : ids) push(app, mgr, id);
        } catch (Exception ignored) {
        }
    }

    private static void push(Context ctx, AppWidgetManager mgr, int id) {
        try {
            SharedPreferences p = Prefs.get(ctx);
            Map<Integer, Integer> m = Stats.load(p);
            int goal = Prefs.getInt(p, Prefs.GOAL_MIN) * 60;
            int today = Stats.secs(m, Stats.cal(0));
            int thisWeek = Stats.sumDays(m, -6, 0);
            int lastWeek = Stats.sumDays(m, -13, -7);
            int[] last7 = Stats.lastDays(m, 7);
            int streak = Stats.streak(m, goal);
            int exam = Stats.examDays(p);
            List<Presets.Preset> presets = QuickStartActivity.visiblePresets(p);
            boolean buttons = !presets.isEmpty();

            float d = ctx.getResources().getDisplayMetrics().density;
            boolean land = ctx.getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE;
            Bundle o = mgr.getAppWidgetOptions(id);
            int wDp = o.getInt(land ? AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH
                    : AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250);
            int hDp = o.getInt(land ? AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
                    : AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 160);
            if (wDp <= 0) wDp = 250;
            if (hDp <= 0) hDp = 160;
            int artW = Math.max(120, Math.min(1400, Math.round((wDp - 16) * d)));
            int artH = Math.max(60, Math.min(800, Math.round((hDp - 16 - (buttons ? 38 : 0)) * d)));

            Bitmap bmp = WidgetArt.draw(artW, artH, d, goal, today, thisWeek, lastWeek, last7, streak, exam);

            RemoteViews rv = new RemoteViews(ctx.getPackageName(), R.layout.widget);
            rv.setImageViewBitmap(R.id.w_art, bmp);
            PendingIntent open = PendingIntent.getActivity(ctx, 99,
                    new Intent(ctx, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            rv.setOnClickPendingIntent(R.id.w_art, open);
            rv.setOnClickPendingIntent(R.id.w_root, open);

            int[] btn = {R.id.w_b0, R.id.w_b1, R.id.w_b2};
            rv.setViewVisibility(R.id.w_row, buttons ? View.VISIBLE : View.GONE);
            for (int i = 0; i < 3; i++) {
                if (i < presets.size()) {
                    Intent in = new Intent(ctx, QuickStartActivity.class);
                    in.putExtra(QuickStartActivity.EXTRA, "p" + i);
                    in.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    PendingIntent pi = PendingIntent.getActivity(ctx, 100 + i, in,
                            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
                    rv.setViewVisibility(btn[i], View.VISIBLE);
                    rv.setTextViewText(btn[i], presets.get(i).name);
                    rv.setOnClickPendingIntent(btn[i], pi);
                } else {
                    rv.setViewVisibility(btn[i], View.GONE);
                }
            }
            mgr.updateAppWidget(id, rv);
        } catch (Exception ignored) {
        }
    }
}
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/WhatsNew.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;

/** The one-time "What's new" dialog after an update, and the "More tips" page. */
final class WhatsNew {
    /** Raise this by one with every update that has news to show. */
    static final int VERSION = 15;

    private WhatsNew() {
    }

    /** News per update, newest first. VERSIONS[i] goes with NEWS[i]. */
    private static final int[] VERSIONS = {15, 14, 13, 12};

    private static final String[] NEWS = {
            "\u2022 Pomodoro break limit is now a fifth of your focus time (25 min focus gives 5 min breaks). "
                    + "The break boxes stop at the limit and shorten themselves when you lower focus time.",
            "\u2022 New widget: ring, exam countdown, this week, change vs last week and a graph. Resize it "
                    + "for a bigger or smaller view.\n\n"
                    + "\u2022 Brighter colours and weekday names on the graph, the Stats tab and the report card.\n\n"
                    + "\u2022 The tile and widget buttons no longer pull the app to the front.\n\n"
                    + "\u2022 Pomodoro breaks are now limited: short up to a fifth of focus, long up to the "
                    + "focus time (max 30 min). Turn it off in Settings.\n\n"
                    + "\u2022 Settings: Download link and Share app link.",
            "\u2022 Desk mode: tap the clock to pause or resume, hold it to restart. Tap the empty space "
                    + "for the buttons.\n\n"
                    + "\u2022 Desk mode now shows today's progress and the exam countdown under the clock.\n\n"
                    + "\u2022 Desk mode is pure black with the AMOLED theme.\n\n"
                    + "\u2022 New Desk mode shortcut icon at the top, next to Settings.",
            "\u2022 New report card: exam days left, this week against last week, and a stock-style graph.\n\n"
                    + "\u2022 The same graph on the Stats tab. Green means goal met, amber means half or more, "
                    + "red means under half.\n\n"
                    + "\u2022 New home-screen widget with today's ring, the weekly change, the graph and "
                    + "three quick-start buttons.\n\n"
                    + "\u2022 New Quick Settings tile. Tap to start, tap again to pause.\n\n"
                    + "\u2022 A shorter tutorial, and a More tips page in Settings."};

    private static final String TIPS = ""
            + "\u2022 Pomodoro breaks are capped (a fifth of focus for short ones). For longer rests use "
            + "Timer, or turn the limit off in Settings.\n\n"
            + "\u2022 Pomodoro: hold the bubble once to restart the step you are in. Hold again within "
            + "5 seconds to reset everything.\n\n"
            + "\u2022 When a Pomodoro break starts, tap the bubble within 10 seconds to skip it.\n\n"
            + "\u2022 The notification has Pause or Resume and Stop, plus Skip break during a break.\n\n"
            + "\u2022 Hold the app icon on your home screen for quick presets and Desk mode.\n\n"
            + "\u2022 Widget: long-press your home screen, choose Widgets, then Watchu. Its three buttons "
            + "start your first three presets.\n\n"
            + "\u2022 Tile: open Quick Settings, tap the pencil and drag Watchu in. Tap to start, tap again "
            + "to pause, hold to open the app.\n\n"
            + "\u2022 Exam colours: green when your last 7 days average meets your daily goal, amber from "
            + "half of it, red below half.\n\n"
            + "\u2022 Desk mode: open it from the icon at the top or the button at the bottom of the Timer "
            + "tab. Tap the clock to pause or resume, hold it to restart, tap the empty space for buttons.\n\n"
            + "\u2022 On the Stats tab, Share report card sends a picture of your week.";

    /** The news newer than version "seen", newest first. With more than one update, each gets a heading. */
    private static String newsSince(int seen) {
        StringBuilder sb = new StringBuilder();
        int count = 0;
        for (int v : VERSIONS) if (v > seen) count++;
        for (int i = 0; i < VERSIONS.length; i++) {
            if (VERSIONS[i] <= seen) continue;
            if (sb.length() > 0) sb.append("\n\n\n");
            if (count > 1) sb.append("Version 1.").append(VERSIONS[i]).append("\n\n");
            sb.append(NEWS[i]);
        }
        return sb.toString();
    }

    private static AlertDialog.Builder builder(Activity a, boolean dark) {
        return new AlertDialog.Builder(a, dark
                ? android.R.style.Theme_DeviceDefault_Dialog_Alert
                : android.R.style.Theme_DeviceDefault_Light_Dialog_Alert);
    }

    /** Shows the news once per update. A brand new install marks it as seen without showing it. */
    static void showIfNew(Activity a, SharedPreferences p, boolean dark) {
        if (Prefs.getInt(p, Prefs.WHATS_SEEN) >= VERSION) return;
        String text = newsSince(Prefs.getInt(p, Prefs.WHATS_SEEN));
        p.edit().putInt(Prefs.WHATS_SEEN, VERSION).apply();
        show(a, dark, "What's new", text);
    }

    /** From Settings: everything that changed, newest first. */
    static void showNews(Activity a, boolean dark) {
        show(a, dark, "What's new", newsSince(0));
    }

    private static void show(Activity a, boolean dark, String title, String text) {
        builder(a, dark).setTitle(title).setMessage(text).setPositiveButton("Got it", null).show();
    }

    static void showTips(Activity a, boolean dark) {
        show(a, dark, "More tips", TIPS);
    }
}
FLOATY_EOF
cat > 'app/src/main/res/drawable/ic_tile.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#00000000"
        android:pathData="M3,12 a9,9 0 1,0 18,0 a9,9 0 1,0 -18,0 M12,7 L12,12 L15.5,14"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:strokeWidth="2" />
</vector>
FLOATY_EOF
cat > 'app/src/main/res/drawable/widget_bg.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#171C25" />
    <corners android:radius="20dp" />
</shape>
FLOATY_EOF
cat > 'app/src/main/res/drawable/widget_btn.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#2A3140" />
    <corners android:radius="16dp" />
</shape>
FLOATY_EOF
mkdir -p 'app/src/main/res/layout'
cat > 'app/src/main/res/layout/widget.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/w_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@drawable/widget_bg"
    android:orientation="vertical"
    android:padding="8dp">

    <ImageView
        android:id="@+id/w_art"
        android:layout_width="match_parent"
        android:layout_height="0dp"
        android:layout_weight="1"
        android:contentDescription="@string/app_name"
        android:scaleType="fitCenter" />

    <LinearLayout
        android:id="@+id/w_row"
        android:layout_width="match_parent"
        android:layout_height="32dp"
        android:layout_marginTop="6dp"
        android:orientation="horizontal">

        <TextView
            android:id="@+id/w_b0"
            android:layout_width="0dp"
            android:layout_height="match_parent"
            android:layout_marginEnd="3dp"
            android:layout_weight="1"
            android:background="@drawable/widget_btn"
            android:ellipsize="end"
            android:gravity="center"
            android:maxLines="1"
            android:paddingStart="6dp"
            android:paddingEnd="6dp"
            android:textColor="#A9C5FF"
            android:textSize="12sp" />

        <TextView
            android:id="@+id/w_b1"
            android:layout_width="0dp"
            android:layout_height="match_parent"
            android:layout_marginStart="3dp"
            android:layout_marginEnd="3dp"
            android:layout_weight="1"
            android:background="@drawable/widget_btn"
            android:ellipsize="end"
            android:gravity="center"
            android:maxLines="1"
            android:paddingStart="6dp"
            android:paddingEnd="6dp"
            android:textColor="#A9C5FF"
            android:textSize="12sp" />

        <TextView
            android:id="@+id/w_b2"
            android:layout_width="0dp"
            android:layout_height="match_parent"
            android:layout_marginStart="3dp"
            android:layout_weight="1"
            android:background="@drawable/widget_btn"
            android:ellipsize="end"
            android:gravity="center"
            android:maxLines="1"
            android:paddingStart="6dp"
            android:paddingEnd="6dp"
            android:textColor="#A9C5FF"
            android:textSize="12sp" />
    </LinearLayout>
</LinearLayout>
FLOATY_EOF
mkdir -p 'app/src/main/res/xml'
cat > 'app/src/main/res/xml/widget_info.xml' <<'FLOATY_EOF'
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/widget_desc"
    android:initialLayout="@layout/widget"
    android:minWidth="250dp"
    android:minHeight="160dp"
    android:minResizeWidth="180dp"
    android:minResizeHeight="110dp"
    android:resizeMode="horizontal|vertical"
    android:targetCellWidth="4"
    android:targetCellHeight="2"
    android:updatePeriodMillis="1800000"
    android:widgetCategory="home_screen" />
FLOATY_EOF
cat > 'app/src/main/java/com/floaty/timer/WidgetArt.java' <<'FLOATY_EOF'
package com.floaty.timer;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;

/** Draws the picture at the top of the home-screen widget. */
final class WidgetArt {
    private static final int SURFACE = 0xFF171C25;
    private static final int TEXT = 0xFFE6E9F0;
    private static final int MUTED = 0xFF8C93A3;

    private WidgetArt() {
    }

    private static float fit(Paint p, String s, float size, float maxW) {
        p.setTextSize(size);
        float w = p.measureText(s);
        return w > maxW && w > 0f ? size * maxW / w : size;
    }

    private static void chip(Canvas c, Paint p, float l, float t, float w, float h, String value, int valueColor,
                             String label, float d) {
        p.setStyle(Paint.Style.FILL);
        p.setShader(null);
        p.setColor(0xFF202735);
        c.drawRoundRect(new RectF(l, t, l + w, t + h), h * 0.3f, h * 0.3f, p);
        p.setTextAlign(Paint.Align.CENTER);
        p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        float vs = fit(p, value, h * 0.40f, w * 0.9f);
        p.setTextSize(vs);
        p.setColor(valueColor);
        c.drawText(value, l + w / 2f, t + h * 0.55f, p);
        p.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        float ls = fit(p, label, Math.max(8f * d, h * 0.22f), w * 0.9f);
        p.setTextSize(ls);
        p.setColor(MUTED);
        c.drawText(label, l + w / 2f, t + h * 0.87f, p);
    }

    static Bitmap draw(int w, int h, float d, int goal, int today, int thisWeek, int lastWeek,
                               int[] last7, int streak, int exam) {
        Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(bmp);
        if (h >= 96f * d && w >= 230f * d) {
            drawFull(c, w, h, d, goal, today, thisWeek, lastWeek, last7, streak, exam);
        } else {
            drawCompact(c, w, h, d, goal, today, thisWeek, lastWeek, last7, exam);
        }
        return bmp;
    }

    /** Ring with today's share, three chips and the week graph with day names. */
    private static void drawFull(Canvas c, int w, int h, float d, int goal, int today, int thisWeek,
                                 int lastWeek, int[] last7, int streak, int exam) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        int pct = Stats.weekPct(thisWeek, lastWeek);
        int tcol = Charts.trend(pct);
        int scol = Charts.status(today, goal);

        float leftW = Math.min(h * 0.80f, w * 0.27f);
        float chipH = h * 0.20f;
        float ringArea = h - chipH - 4f * d;
        float ringD = Math.min(leftW, ringArea);
        float stroke = ringD * 0.11f;
        float r = ringD / 2f - stroke * 0.9f;
        float cx = leftW / 2f;
        float cy = ringArea / 2f;
        float frac = goal > 0 ? Math.min(1f, today / (float) goal) : 0f;
        Charts.ring(c, cx, cy, r, stroke, frac, scol, 0xFF262D3A);
        p.setTextAlign(Paint.Align.CENTER);
        p.setStyle(Paint.Style.FILL);
        p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        String big = Stats.dur(today);
        float bs = fit(p, big, r * 0.62f, r * 1.5f);
        p.setTextSize(bs);
        p.setColor(0xFFFFFFFF);
        c.drawText(big, cx, cy + bs * 0.12f, p);
        p.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        String of = "of " + Stats.dur(goal);
        float os = fit(p, of, r * 0.34f, r * 1.4f);
        p.setTextSize(os);
        p.setColor(MUTED);
        c.drawText(of, cx, cy + bs * 0.12f + os * 1.4f, p);

        // share of the goal, under the ring
        int share = goal > 0 ? Math.round(today * 100f / goal) : 0;
        float cw = leftW * 0.78f;
        float ct = h - chipH;
        p.setStyle(Paint.Style.FILL);
        p.setColor(0xFF202735);
        c.drawRoundRect(new RectF(cx - cw / 2f, ct, cx + cw / 2f, h), chipH / 2f, chipH / 2f, p);
        p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        float ss = fit(p, share + "%", chipH * 0.55f, cw * 0.8f);
        p.setTextSize(ss);
        p.setColor(scol);
        c.drawText(share + "%", cx, ct + chipH / 2f + ss * 0.35f, p);

        // chips
        float x0 = leftW + 10f * d;
        float rw = w - x0 - 2f * d;
        float chipsH = h * 0.31f;
        float gap = 6f * d;
        float each = (rw - 2f * gap) / 3f;
        int ecol = Charts.status(thisWeek / 7, goal);
        if (exam >= 0) {
            chip(c, p, x0, 0f, each, chipsH, exam == 0 ? "Today" : exam + "d", ecol, "Exam", d);
        } else {
            chip(c, p, x0, 0f, each, chipsH, streak + (streak == 1 ? " day" : " days"), TEXT, "Streak", d);
        }
        chip(c, p, x0 + each + gap, 0f, each, chipsH, Stats.dur(thisWeek), TEXT, "This week", d);
        chip(c, p, x0 + 2f * (each + gap), 0f, each, chipsH, Stats.pctText(pct), tcol, "vs last week", d);

        // graph panel
        float gt = chipsH + 6f * d;
        float gh = h - gt;
        p.setStyle(Paint.Style.FILL);
        p.setShader(null);
        p.setColor(0xFF10141B);
        c.drawRoundRect(new RectF(x0, gt, x0 + rw, h), 14f * d, 14f * d, p);
        Charts.Style st = new Charts.Style();
        st.fs = Math.max(8f * d, Math.min(11f * d, gh * 0.11f));
        st.dot = Math.max(1.8f * d, gh * 0.03f);
        st.line = Math.max(1.8f * d, gh * 0.04f);
        st.axis = true;
        st.tag = true;
        st.goalLabel = gh > 60f * d;
        st.valueLine = true;
        st.labels = Stats.dayLabels(last7.length, 1);
        st.surface = 0xFF10141B;
        st.textColor = MUTED;
        st.textStrong = TEXT;
        Charts.stock(c, x0 + 4f * d, gt, rw - 8f * d, gh, last7, goal, st);
    }

    /** Small widgets: ring, weekly change, exam box and a small graph. */
    private static void drawCompact(Canvas c, int w, int h, float d, int goal, int today, int thisWeek,
                                    int lastWeek, int[] last7, int exam) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        int pct = Stats.weekPct(thisWeek, lastWeek);
        int tcol = Charts.trend(pct);

        // today ring on the left
        float leftW = Math.min(h, w * 0.30f);
        float stroke = leftW * 0.10f;
        float r = leftW / 2f - stroke * 0.9f;
        float cx = leftW / 2f;
        float cy = h / 2f;
        float frac = goal > 0 ? Math.min(1f, today / (float) goal) : 0f;
        Charts.ring(c, cx, cy, r, stroke, frac, Charts.status(today, goal), 0xFF262D3A);
        p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        p.setTextAlign(Paint.Align.CENTER);
        p.setStyle(Paint.Style.FILL);
        String big = Stats.dur(today);
        float bs = fit(p, big, r * 0.55f, r * 1.45f);
        p.setTextSize(bs);
        p.setColor(TEXT);
        boolean small = r >= 26f * d;
        c.drawText(big, cx, small ? cy : cy + bs * 0.35f, p);
        if (small) {
            p.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            String of = "of " + Stats.dur(goal);
            float ss = fit(p, of, r * 0.30f, r * 1.4f);
            p.setTextSize(ss);
            p.setColor(MUTED);
            c.drawText(of, cx, cy + bs * 0.35f + ss * 1.25f, p);
        }

        // right side: weekly change and exam on top, graph below
        float x0 = leftW + 10f * d;
        float rw = w - x0 - 2f * d;
        boolean graph = h >= 56f * d && rw >= 110f * d;
        float topH = graph ? h * 0.36f : h;
        float topCy = graph ? topH / 2f : h / 2f;

        float exW = 0f;
        if (exam >= 0) {
            int ecol = Charts.status(thisWeek / 7, goal);
            String et = exam == 0 ? "EXAM DAY" : "EXAM " + exam + "d";
            float bh = Math.min(topH * 0.86f, 26f * d);
            p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            float es = bh * 0.46f;
            p.setTextSize(es);
            float tw = p.measureText(et);
            exW = tw + bh * 0.9f;
            float ex1 = x0 + rw;
            p.setStyle(Paint.Style.FILL);
            p.setColor(Charts.alpha(ecol, 0x33));
            c.drawRoundRect(new RectF(ex1 - exW, topCy - bh / 2f, ex1, topCy + bh / 2f), bh / 2f, bh / 2f, p);
            p.setColor(ecol);
            p.setTextAlign(Paint.Align.CENTER);
            c.drawText(et, ex1 - exW / 2f, topCy + es * 0.35f, p);
        }

        float avail = rw - (exW > 0f ? exW + 8f * d : 0f);
        float px = x0;
        float ps = Math.min(topH * 0.62f, 30f * d);
        if (pct != Stats.NO_PCT && pct != 0) {
            float tsz = ps * 0.62f;
            Path tri = new Path();
            if (pct > 0) {
                tri.moveTo(px, topCy + tsz / 2f);
                tri.lineTo(px + tsz, topCy + tsz / 2f);
                tri.lineTo(px + tsz / 2f, topCy - tsz / 2f);
            } else {
                tri.moveTo(px, topCy - tsz / 2f);
                tri.lineTo(px + tsz, topCy - tsz / 2f);
                tri.lineTo(px + tsz / 2f, topCy + tsz / 2f);
            }
            tri.close();
            p.setStyle(Paint.Style.FILL);
            p.setColor(tcol);
            c.drawPath(tri, p);
            px += tsz + 5f * d;
            avail -= tsz + 5f * d;
        }
        String pt = Stats.pctText(pct);
        p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        float pfs = fit(p, pt, ps, Math.max(20f * d, avail * 0.62f));
        p.setTextSize(pfs);
        p.setColor(tcol);
        p.setTextAlign(Paint.Align.LEFT);
        c.drawText(pt, px, topCy + pfs * 0.35f, p);
        float pw = p.measureText(pt);
        String vs = "vs last week";
        p.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        float vsz = Math.min(pfs * 0.42f, 11f * d);
        p.setTextSize(vsz);
        if (vsz >= 7f * d && p.measureText(vs) < avail - pw - 6f * d) {
            p.setColor(MUTED);
            c.drawText(vs, px + pw + 6f * d, topCy + vsz * 0.35f, p);
        }

        if (graph) {
            Charts.Style st = new Charts.Style();
            st.fs = Math.max(8f * d, h * 0.10f);
            st.dot = Math.max(1.8f * d, h * 0.024f);
            st.line = Math.max(1.8f * d, h * 0.032f);
            st.valueLine = true;
            st.surface = SURFACE;
            st.textColor = MUTED;
            float gt = topH + 2f * d;
            Charts.stock(c, x0, gt, rw, h - gt, last7, goal, st);
        }
    }
}
FLOATY_EOF
cat > 'build.gradle' <<'FLOATY_EOF'
plugins {
    id 'com.android.application' version '8.5.2' apply false
}
FLOATY_EOF
cat > 'gradle.properties' <<'FLOATY_EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.nonTransitiveRClass=true
FLOATY_EOF
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
