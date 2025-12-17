package com.sumsg.metronome_plus;

import static android.media.AudioTrack.PLAYSTATE_PLAYING;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Build;

import android.media.AudioAttributes;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import io.flutter.plugin.common.EventChannel;

public class Metronome {
    private final Object mLock = new Object();
    private final AudioTrack audioTrack;
    private short[] mainSound;
    private short[] accentedSound;
    private short[] preCountMainSound;
    private short[] preCountAccentedSound;
    private short[] audioBuffer;
    private final int SAMPLE_RATE;
    public int audioBpm;
    public int audioTimeSignature;
    public float audioVolume;
    private boolean updated = false;
    private EventChannel.EventSink eventTickSink;
    private int currentTick = 0;
    private int preCountBarsConfigured = 0;
    private boolean isInPreCount = false;
    private boolean isFirstTick = false;
    // How many pre-count bars remain to be written into the audio queue
    private int remainingPreCountBarsToWrite = 0;

    @SuppressWarnings("deprecation")
    public Metronome(byte[] mainFileBytes, byte[] accentedFileBytes, int bpm, int timeSignature, float volume,
            int sampleRate, int preCountBars, byte[] preCountMainFileBytes, byte[] preCountAccentedFileBytes) {
        SAMPLE_RATE = sampleRate;
        audioBpm = bpm;
        audioVolume = volume;
        audioTimeSignature = timeSignature;
        mainSound = byteArrayToShortArray(mainFileBytes);
        if (accentedFileBytes.length == 0) {
            accentedSound = mainSound;
        } else {
            accentedSound = byteArrayToShortArray(accentedFileBytes);
        }
        preCountMainSound = (preCountMainFileBytes.length == 0) ? mainSound : byteArrayToShortArray(preCountMainFileBytes);
        preCountAccentedSound = (preCountAccentedFileBytes.length == 0) ? accentedSound
                : byteArrayToShortArray(preCountAccentedFileBytes);
        preCountBarsConfigured = Math.max(0, preCountBars);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioFormat audioFormat = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build();
            AudioAttributes audioAttributes = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build();
            audioTrack = new AudioTrack.Builder()
                    .setAudioAttributes(audioAttributes)
                    .setAudioFormat(audioFormat)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    // .setBufferSizeInBytes(SAMPLE_RATE)
                    // .setBufferSizeInBytes(SAMPLE_RATE * 2)
                    .build();
        } else {
            audioTrack = new AudioTrack(AudioManager.STREAM_MUSIC, SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, SAMPLE_RATE, AudioTrack.MODE_STREAM);
        }
        setVolume(volume);
    }

    public void play() {
        play(-1);
    }

    public void play(int preCountBarsOverride) {
        if (!isPlaying()) {
            int bars = (preCountBarsOverride >= 0) ? preCountBarsOverride : preCountBarsConfigured;
            isInPreCount = bars > 0;
            currentTick = isInPreCount ? -(bars * audioTimeSignature) : 0;
            remainingPreCountBarsToWrite = Math.max(0, bars);
            updated = true;
            isFirstTick = true;
            onTick();
            if (eventTickSink != null) {
                eventTickSink.success(currentTick);
            }
            audioTrack.play();
            startMetronome();
        }
    }

    public void pause() {
        audioTrack.pause();
    }

    public void stop() {
        audioTrack.flush();
        audioTrack.stop();
    }

    public void setBPM(int bpm) {
        if (bpm != audioBpm) {
            audioBpm = bpm;
            if (isPlaying()) {
                pause();
                play(0);
            }
        }
    }

    public void setTimeSignature(int timeSignature) {
        if (timeSignature != audioTimeSignature) {
            audioTimeSignature = timeSignature;
            if (isPlaying()) {
                pause();
                play(0);
            }
        }
    }

    public void setAudioFile(byte[] mainFileBytes, byte[] accentedFileBytes) {
        if (mainFileBytes.length > 0) {
            mainSound = byteArrayToShortArray(mainFileBytes);
        }
        if (accentedFileBytes.length > 0) {
            accentedSound = byteArrayToShortArray(accentedFileBytes);
        }
        if (mainFileBytes.length > 0 || accentedFileBytes.length > 0) {
            if (isPlaying()) {
                pause();
                play();
            }
        }
    }

    @SuppressWarnings("deprecation")
    public void setVolume(float volume) {
        audioVolume = volume;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            audioTrack.setVolume(volume);
        } else {
            audioTrack.setStereoVolume(volume, volume);
        }
    }

    public boolean isPlaying() {
        return audioTrack.getPlayState() == PLAYSTATE_PLAYING;
    }

    public void enableTickCallback(EventChannel.EventSink _eventTickSink) {
        eventTickSink = _eventTickSink;
    }

    private short[] byteArrayToShortArray(byte[] byteArray) {
        if (byteArray == null || byteArray.length % 2 != 0) {
            throw new IllegalArgumentException("Invalid byte array length for PCM_16BIT");
        }
        short[] shortArray = new short[byteArray.length / 2];
        ByteBuffer.wrap(byteArray).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(shortArray);
        return shortArray;
    }

    private short[] generateBuffer() {
        int framesPerBeat = (int) (SAMPLE_RATE * 60 / (float) audioBpm);
        short[] bufferBar;
        // Decide whether this bar should use pre-count sounds
        boolean usePrecount = remainingPreCountBarsToWrite > 0;
        if (audioTimeSignature < 2) {
            bufferBar = new short[framesPerBeat];
            short[] sound = usePrecount ? preCountAccentedSound : accentedSound;
            int soundLength = Math.min(framesPerBeat, sound.length);
            System.arraycopy(sound, 0, bufferBar, 0, soundLength);
        } else {
            int bufferSize = framesPerBeat * audioTimeSignature;
            bufferBar = new short[bufferSize];
            for (int i = 0; i < audioTimeSignature; i++) {
                boolean isStrongBeat = (i == 0);
                short[] sound;
                if (usePrecount) {
                    sound = isStrongBeat ? preCountAccentedSound : preCountMainSound;
                } else {
                    sound = isStrongBeat ? accentedSound : mainSound;
                }
                int soundLength = Math.min(framesPerBeat, sound.length);
                System.arraycopy(sound, 0, bufferBar, i * framesPerBeat, soundLength);
            }
        }
        // Consume one scheduled pre-count bar if used
        if (usePrecount && remainingPreCountBarsToWrite > 0) {
            remainingPreCountBarsToWrite--;
        }
        // updated フラグはここでは変更しない
        return bufferBar;
    }

    void onTick() {
        if (eventTickSink == null)
            return;
        int framesPerBeat = (int) ((SAMPLE_RATE * 60.0) / audioBpm);
        audioTrack.setPositionNotificationPeriod(framesPerBeat);
        audioTrack.setPlaybackPositionUpdateListener(new AudioTrack.OnPlaybackPositionUpdateListener() {
            @Override
            public void onMarkerReached(AudioTrack track) {
            }

            @Override
            public void onPeriodicNotification(AudioTrack track) {
                if (isFirstTick) {
                    isFirstTick = false;
                    return;
                }
                if (isInPreCount) {
                    currentTick++;
                    if (currentTick == 0) {
                        isInPreCount = false;
                        updated = true;
                    }
                    if (eventTickSink != null) {
                        eventTickSink.success(currentTick);
                    }
                } else {
                    currentTick++;
                    if (currentTick >= audioTimeSignature)
                        currentTick = 0;
                    if (eventTickSink != null) {
                        eventTickSink.success(currentTick);
                    }
                }
            }
        });
    }

    private void startMetronome() {
        new Thread(() -> {
            while (isPlaying()) {
                synchronized (mLock) {
                    if (!isPlaying()) {
                        return;
                    }
                    // Always prepare the next bar buffer so that we don't repeat the same buffer.
                    // The buffer content is determined by remainingPreCountBarsToWrite and current settings.
                    audioBuffer = generateBuffer();
                    updated = false;  // バッファ生成後すぐにリセット（互換のために維持）
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        audioTrack.write(audioBuffer, 0, audioBuffer.length, AudioTrack.WRITE_BLOCKING);
                    } else {
                        audioTrack.write(audioBuffer, 0, audioBuffer.length);
                    }
                }
            }
        }).start();
    }

    public void destroy() {
        stop();
        audioTrack.release();
    }
}
