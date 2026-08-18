#!/bin/bash
set -e

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/android-sdk}
PLATFORM=$ANDROID_HOME/platforms/android-34/android.jar
BUILD_TOOLS=$ANDROID_HOME/build-tools/34.0.0

PROJECT="$(cd "$(dirname "$0")" && pwd)"
SRC=$PROJECT/app/src/main
OUT=$PROJECT/build
PKG_PATH=dev/linjian/peek
JAVA_DIR=$SRC/java/$PKG_PATH

inject_media_awareness() {
    echo "=== Injecting personal media awareness v0.1 ==="
    mkdir -p "$JAVA_DIR"

    cat > "$JAVA_DIR/MediaNotificationListener.java" <<'JAVA'
package dev.linjian.peek;

import android.service.notification.NotificationListenerService;

/**
 * Grants this app eligibility to query active Android MediaSessions after the
 * device owner explicitly enables Notification access for 掌心窗.
 *
 * This service does not upload notification bodies or store notification text.
 */
public class MediaNotificationListener extends NotificationListenerService {
}
JAVA

    cat > "$JAVA_DIR/MediaState.java" <<'JAVA'
package dev.linjian.peek;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.SystemClock;
import android.provider.Settings;

import org.json.JSONObject;

import java.util.List;

/** Lightweight now-playing state backed by Android MediaSession. */
public final class MediaState {
    private MediaState() { }

    public static JSONObject collect(Context ctx) {
        JSONObject out = new JSONObject();
        try {
            boolean permissionReady = hasNotificationAccess(ctx);
            AudioManager audio = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
            boolean musicActive = audio != null && audio.isMusicActive();

            out.put("source", "android_media_session");
            out.put("notification_access_ready", permissionReady);
            out.put("music_active", musicActive);
            out.put("available", false);

            if (!permissionReady) {
                out.put("playback", "unknown");
                out.put("error", "notification_access_required");
                out.put("hint", "请在 Android 系统设置的“通知使用权 / Notification access”中允许“掌心窗”。");
                return out;
            }

            MediaSessionManager manager =
                    (MediaSessionManager) ctx.getSystemService(Context.MEDIA_SESSION_SERVICE);
            if (manager == null) {
                out.put("playback", "none");
                out.put("error", "media_session_manager_unavailable");
                return out;
            }

            ComponentName listener = new ComponentName(ctx, MediaNotificationListener.class);
            List<MediaController> sessions = manager.getActiveSessions(listener);
            int sessionCount = sessions == null ? 0 : sessions.size();
            out.put("session_count", sessionCount);

            if (sessions == null || sessions.isEmpty()) {
                out.put("playback", "none");
                return out;
            }

            MediaController best = null;
            int bestScore = Integer.MIN_VALUE;
            for (MediaController controller : sessions) {
                if (controller == null) continue;
                int score = score(controller);
                if (best == null || score > bestScore) {
                    best = controller;
                    bestScore = score;
                }
            }

            if (best == null) {
                out.put("playback", "none");
                return out;
            }

            String pkg = safe(best.getPackageName());
            String app = appLabel(ctx, pkg);
            MediaMetadata metadata = best.getMetadata();
            PlaybackState playbackState = best.getPlaybackState();

            String title = metadataText(metadata, MediaMetadata.METADATA_KEY_TITLE);
            if (title.isEmpty()) {
                title = metadataText(metadata, MediaMetadata.METADATA_KEY_DISPLAY_TITLE);
            }

            String artist = metadataText(metadata, MediaMetadata.METADATA_KEY_ARTIST);
            if (artist.isEmpty()) {
                artist = metadataText(metadata, MediaMetadata.METADATA_KEY_ALBUM_ARTIST);
            }
            if (artist.isEmpty()) {
                artist = metadataText(metadata, MediaMetadata.METADATA_KEY_AUTHOR);
            }
            if (artist.isEmpty()) {
                artist = metadataText(metadata, MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE);
            }

            String album = metadataText(metadata, MediaMetadata.METADATA_KEY_ALBUM);
            long duration = metadata == null ? -1L
                    : metadata.getLong(MediaMetadata.METADATA_KEY_DURATION);
            long position = estimatedPosition(playbackState, duration);
            String playback = playbackName(playbackState);
            boolean playing = playbackState != null
                    && playbackState.getState() == PlaybackState.STATE_PLAYING;

            out.put("available", true);
            out.put("package", pkg);
            out.put("app", app);
            out.put("title", title);
            out.put("artist", artist);
            out.put("album", album);
            out.put("playback", playback);
            out.put("playing", playing);
            out.put("position_ms", position);
            out.put("duration_ms", duration);
            out.put("playback_speed",
                    playbackState == null ? 0.0 : playbackState.getPlaybackSpeed());
            out.put("updated_at_ms", System.currentTimeMillis());
        } catch (SecurityException e) {
            try {
                out.put("available", false);
                out.put("notification_access_ready", false);
                out.put("error", "notification_access_required");
                out.put("hint", "请在 Android 系统设置的“通知使用权 / Notification access”中允许“掌心窗”。");
            } catch (Exception ignored) { }
        } catch (Exception e) {
            try {
                out.put("available", false);
                out.put("error", e.getClass().getSimpleName() + ": " + safe(e.getMessage()));
            } catch (Exception ignored) { }
        }
        return out;
    }

    public static String summary(JSONObject state) {
        if (state == null) return "当前媒体状态不可用";
        if (!state.optBoolean("notification_access_ready", false)) {
            return "媒体感知未授权：需要开启通知使用权";
        }
        if (!state.optBoolean("available", false)) {
            return state.optBoolean("music_active", false)
                    ? "检测到音频活动，但没有可读的 MediaSession"
                    : "当前没有活跃媒体";
        }

        String title = state.optString("title", "");
        String artist = state.optString("artist", "");
        String playback = state.optString("playback", "unknown");

        StringBuilder sb = new StringBuilder();
        if ("playing".equals(playback)) sb.append("正在播放：");
        else if ("paused".equals(playback)) sb.append("已暂停：");
        else sb.append("当前媒体：");

        if (!artist.isEmpty()) sb.append(artist);
        if (!artist.isEmpty() && !title.isEmpty()) sb.append(" - ");
        if (!title.isEmpty()) sb.append(title);
        if (artist.isEmpty() && title.isEmpty()) {
            String app = state.optString("app", "");
            sb.append(app.isEmpty() ? "未知媒体" : app);
        }
        return sb.toString();
    }

    private static int score(MediaController controller) {
        int score = 0;
        try {
            String pkg = safe(controller.getPackageName());
            PlaybackState state = controller.getPlaybackState();
            MediaMetadata metadata = controller.getMetadata();

            if (state != null) {
                switch (state.getState()) {
                    case PlaybackState.STATE_PLAYING: score += 1000; break;
                    case PlaybackState.STATE_BUFFERING:
                    case PlaybackState.STATE_CONNECTING: score += 800; break;
                    case PlaybackState.STATE_PAUSED: score += 500; break;
                    default: score += 100; break;
                }
            }
            if ("com.netease.cloudmusic".equals(pkg)) score += 120;
            if (metadata != null) {
                String title = metadataText(metadata, MediaMetadata.METADATA_KEY_TITLE);
                if (!title.isEmpty()) score += 40;
            }
        } catch (Exception ignored) { }
        return score;
    }

    private static long estimatedPosition(PlaybackState state, long duration) {
        if (state == null) return -1L;
        long position = state.getPosition();
        if (state.getState() == PlaybackState.STATE_PLAYING) {
            long last = state.getLastPositionUpdateTime();
            if (last > 0) {
                long elapsed = Math.max(0L, SystemClock.elapsedRealtime() - last);
                position += (long) (elapsed * state.getPlaybackSpeed());
            }
        }
        position = Math.max(0L, position);
        if (duration > 0) position = Math.min(position, duration);
        return position;
    }

    private static String playbackName(PlaybackState state) {
        if (state == null) return "unknown";
        switch (state.getState()) {
            case PlaybackState.STATE_NONE: return "none";
            case PlaybackState.STATE_STOPPED: return "stopped";
            case PlaybackState.STATE_PAUSED: return "paused";
            case PlaybackState.STATE_PLAYING: return "playing";
            case PlaybackState.STATE_FAST_FORWARDING: return "fast_forwarding";
            case PlaybackState.STATE_REWINDING: return "rewinding";
            case PlaybackState.STATE_BUFFERING: return "buffering";
            case PlaybackState.STATE_ERROR: return "error";
            case PlaybackState.STATE_CONNECTING: return "connecting";
            case PlaybackState.STATE_SKIPPING_TO_PREVIOUS: return "skipping_previous";
            case PlaybackState.STATE_SKIPPING_TO_NEXT: return "skipping_next";
            case PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM: return "skipping_queue_item";
            default: return "unknown";
        }
    }

    private static String metadataText(MediaMetadata metadata, String key) {
        if (metadata == null || key == null) return "";
        try {
            CharSequence value = metadata.getText(key);
            return value == null ? "" : value.toString().trim();
        } catch (Exception e) {
            try {
                String value = metadata.getString(key);
                return value == null ? "" : value.trim();
            } catch (Exception ignored) {
                return "";
            }
        }
    }

    private static boolean hasNotificationAccess(Context ctx) {
        try {
            String enabled = Settings.Secure.getString(
                    ctx.getContentResolver(), "enabled_notification_listeners");
            if (enabled == null || enabled.trim().isEmpty()) return false;
            String packageName = ctx.getPackageName();
            for (String item : enabled.split(":")) {
                ComponentName component = ComponentName.unflattenFromString(item);
                if (component != null && packageName.equals(component.getPackageName())) {
                    return true;
                }
            }
        } catch (Exception ignored) { }
        return false;
    }

    private static String appLabel(Context ctx, String pkg) {
        if (pkg == null || pkg.trim().isEmpty()) return "";
        try {
            PackageManager pm = ctx.getPackageManager();
            ApplicationInfo info = pm.getApplicationInfo(pkg.trim(), 0);
            CharSequence label = pm.getApplicationLabel(info);
            return label == null ? pkg : label.toString();
        } catch (Exception e) {
            return pkg;
        }
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }
}
JAVA

    python3 - "$SRC/AndroidManifest.xml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if 'com.netease.cloudmusic' not in text:
    needle = '        <package android:name="com.twitter.android" />'
    replacement = needle + '\n        <package android:name="com.netease.cloudmusic" />'
    if needle in text:
        text = text.replace(needle, replacement, 1)

if 'android:name=".MediaNotificationListener"' not in text:
    service = '''
        <service
            android:name=".MediaNotificationListener"
            android:label="掌心窗媒体感知"
            android:exported="true"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService" />
            </intent-filter>
        </service>

'''
    if '    </application>' not in text:
        raise SystemExit("Could not find </application> in AndroidManifest.xml")
    text = text.replace('    </application>', service + '    </application>', 1)

path.write_text(text, encoding="utf-8")
PY

    python3 - "$JAVA_DIR/LifeState.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

marker = '            state.put("current_app", currentApp);'
injection = '''            state.put("current_app", currentApp);
            JSONObject mediaState = MediaState.collect(ctx);
            state.put("media_state", mediaState);
            state.put("media_summary", MediaState.summary(mediaState));'''

if 'state.put("media_state", mediaState);' not in text:
    if marker not in text:
        raise SystemExit("Could not find LifeState current_app insertion point")
    text = text.replace(marker, injection, 1)

pretty_marker = '            sb.append("\\n").append(s.optString("summary", ""));'
pretty_injection = '''            sb.append("\\n").append(s.optString("summary", ""));
            String mediaSummary = s.optString("media_summary", "");
            if (!mediaSummary.isEmpty()) sb.append("\\n媒体：").append(mediaSummary);'''

if 'String mediaSummary = s.optString("media_summary", "");' not in text:
    if pretty_marker not in text:
        raise SystemExit("Could not find LifeState pretty insertion point")
    text = text.replace(pretty_marker, pretty_injection, 1)

path.write_text(text, encoding="utf-8")
PY

    echo "Media awareness injected."
}

if [ ! -f "$PLATFORM" ]; then
  echo "Android platform not found: $PLATFORM"
  echo "Install Android SDK platform 34 first."
  exit 1
fi

inject_media_awareness

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/apk" "$OUT/compiled_res"

echo "=== Compiling resources ==="
$BUILD_TOOLS/aapt2 compile --dir "$SRC/res" -o "$OUT/compiled_res/"

echo "=== Linking resources ==="
$BUILD_TOOLS/aapt2 link \
    -o "$OUT/apk/app.unsigned.apk" \
    -I "$PLATFORM" \
    --manifest "$SRC/AndroidManifest.xml" \
    --java "$OUT/gen" \
    --auto-add-overlay \
    -R "$OUT/compiled_res"/*.flat

echo "=== Compiling Java ==="
find "$SRC/java" -name "*.java" > "$OUT/sources.txt"
echo "$OUT/gen/$PKG_PATH/R.java" >> "$OUT/sources.txt"
javac -encoding UTF-8 -source 11 -target 11 -classpath "$PLATFORM" -d "$OUT/classes" @"$OUT/sources.txt"

echo "=== Creating DEX ==="
$BUILD_TOOLS/d8 --output "$OUT/apk/" --lib "$PLATFORM" $(find "$OUT/classes" -name "*.class")

echo "=== Building APK ==="
cd "$OUT/apk"
cp app.unsigned.apk app.tmp.apk
zip -d app.tmp.apk classes.dex 2>/dev/null || true
zip -j app.tmp.apk classes.dex
mv app.tmp.apk app.unsigned.apk

echo "=== Loading fixed PUBLIC signing key ==="
PUBLIC_KS=$PROJECT/signing/zhangxinchuang-public-release.p12
PUBLIC_KS_PASSWORD=${PUBLIC_KS_PASSWORD:-zhangxinchuang-public-30600}
if [ ! -f "$PUBLIC_KS" ]; then
    echo "Public release keystore not found: $PUBLIC_KS"
    exit 1
fi

echo "=== Aligning ==="
$BUILD_TOOLS/zipalign -f 4 app.unsigned.apk app.aligned.apk

echo "=== Signing public APK ==="
$BUILD_TOOLS/apksigner sign \
    --ks "$PUBLIC_KS" \
    --ks-type PKCS12 \
    --ks-pass pass:"$PUBLIC_KS_PASSWORD" \
    --key-pass pass:"$PUBLIC_KS_PASSWORD" \
    --ks-key-alias zhangxinchuang-public \
    --out "$PROJECT/Zhangxinchuang-public-v0.3.6.5.apk" \
    app.aligned.apk

echo "=== Verifying fixed public signature ==="
VERIFY_OUTPUT=$($BUILD_TOOLS/apksigner verify --verbose --print-certs "$PROJECT/Zhangxinchuang-public-v0.3.6.5.apk")
echo "$VERIFY_OUTPUT"
echo "$VERIFY_OUTPUT" | grep -qi "aea75c9b2b5f5c42d56b72d4a69a79a38e1c57f27db021017be8656bc8f002fb"

echo ""
echo "=== Done ==="
echo "APK: $PROJECT/Zhangxinchuang-public-v0.3.6.5.apk"
ls -lh "$PROJECT/Zhangxinchuang-public-v0.3.6.5.apk"
