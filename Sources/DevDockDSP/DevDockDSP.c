#include "DevDockDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define DD_MAX_CHANNELS 8
#define DD_RING_SIZE 4096u /* power of two */
#define DD_SILENCE_THRESHOLD 1.0e-5f
#define DD_PI 3.14159265358979323846

static const double kBandFrequencies[DD_EQ_BANDS] = {
    31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0
};

typedef struct {
    double b0, b1, b2, a1, a2; /* normalized by a0 */
    int active;                /* 0 for a 0 dB band, which is skipped */
} DDBiquad;

typedef struct {
    DDBiquad bands[DD_EQ_BANDS];
    float preamp; /* linear gain */
} DDCoefficients;

struct DDEqualizer {
    double sampleRate;

    /* Written by the main thread under a sequence lock, copied by the audio thread. */
    DDCoefficients shared;
    atomic_uint sequence;

    /* Audio thread only. */
    DDCoefficients current;
    unsigned appliedSequence;
    double state[DD_MAX_CHANNELS][DD_EQ_BANDS][2];

    /* Audio thread writes, main thread reads. */
    float ring[DD_RING_SIZE];
    atomic_uint ringWrite; /* total samples written; wraps */
    atomic_ullong silentFrames;
    atomic_int heardAudio;
};

static DDBiquad dd_identity(void) {
    DDBiquad q = { 1.0, 0.0, 0.0, 0.0, 0.0, 0 };
    return q;
}

/* RBJ Audio EQ Cookbook coefficients. */
static DDBiquad dd_make_band(int index, double gainDB, double sampleRate) {
    if (fabs(gainDB) < 0.01) return dd_identity();

    double f0 = kBandFrequencies[index];
    double limit = sampleRate * 0.45; /* stay clear of Nyquist on low-rate devices */
    if (f0 > limit) f0 = limit;

    double A = pow(10.0, gainDB / 40.0);
    double w0 = 2.0 * DD_PI * f0 / sampleRate;
    double cosw = cos(w0);
    double sinw = sin(w0);
    double b0, b1, b2, a0, a1, a2;

    /* Peaking filters throughout, so each slider's full gain lands on its labeled frequency.
       The two edge bands are wider (Q 0.9) so they sweep the deep bass and the air like a
       shelf would; the middle bands use Q 1.41, about one octave, matching their spacing. */
    double Q = (index == 0 || index == DD_EQ_BANDS - 1) ? 0.9 : 1.41;
    double alpha = sinw / (2.0 * Q);
    b0 = 1.0 + alpha * A;
    b1 = -2.0 * cosw;
    b2 = 1.0 - alpha * A;
    a0 = 1.0 + alpha / A;
    a1 = -2.0 * cosw;
    a2 = 1.0 - alpha / A;

    DDBiquad q;
    q.b0 = b0 / a0;
    q.b1 = b1 / a0;
    q.b2 = b2 / a0;
    q.a1 = a1 / a0;
    q.a2 = a2 / a0;
    q.active = 1;
    return q;
}

static inline float dd_soft_limit(float x) {
    const float threshold = 0.89f;
    float magnitude = fabsf(x);
    if (magnitude <= threshold) return x;
    float over = (magnitude - threshold) / (1.0f - threshold);
    float limited = threshold + (1.0f - threshold) * tanhf(over);
    return x < 0.0f ? -limited : limited;
}

static void dd_count_silence(DDEqualizer *eq, UInt32 frames) {
    atomic_fetch_add_explicit(&eq->silentFrames, (unsigned long long)frames, memory_order_relaxed);
}

/* Audio thread: adopt new coefficients if the main thread published a complete set. */
static void dd_refresh_coefficients(DDEqualizer *eq) {
    unsigned before = atomic_load_explicit(&eq->sequence, memory_order_acquire);
    if ((before & 1u) != 0 || before == eq->appliedSequence) return;

    DDCoefficients copy = eq->shared;
    atomic_thread_fence(memory_order_acquire);
    unsigned after = atomic_load_explicit(&eq->sequence, memory_order_relaxed);
    if (before != after) return; /* torn read; try again next callback */

    /* A band switching on or off starts from clean state so it doesn't click. */
    for (int b = 0; b < DD_EQ_BANDS; b++) {
        if (copy.bands[b].active != eq->current.bands[b].active) {
            for (int c = 0; c < DD_MAX_CHANNELS; c++) {
                eq->state[c][b][0] = 0.0;
                eq->state[c][b][1] = 0.0;
            }
        }
    }
    eq->current = copy;
    eq->appliedSequence = before;
}

DDEqualizer *dd_eq_create(double sampleRate) {
    DDEqualizer *eq = calloc(1, sizeof(DDEqualizer));
    if (eq == NULL) return NULL;
    eq->sampleRate = sampleRate > 0.0 ? sampleRate : 48000.0;
    for (int b = 0; b < DD_EQ_BANDS; b++) {
        eq->shared.bands[b] = dd_identity();
    }
    eq->shared.preamp = 1.0f;
    eq->current = eq->shared;
    eq->appliedSequence = 0;
    atomic_init(&eq->sequence, 0u);
    atomic_init(&eq->ringWrite, 0u);
    atomic_init(&eq->silentFrames, 0ull);
    atomic_init(&eq->heardAudio, 0);
    return eq;
}

void dd_eq_destroy(DDEqualizer *eq) {
    free(eq);
}

void dd_eq_set_gains(DDEqualizer *eq, const float *gainsDB, float preampDB) {
    if (eq == NULL || gainsDB == NULL) return;

    DDCoefficients next;
    for (int b = 0; b < DD_EQ_BANDS; b++) {
        next.bands[b] = dd_make_band(b, (double)gainsDB[b], eq->sampleRate);
    }
    next.preamp = powf(10.0f, preampDB / 20.0f);

    /* Sequence lock: odd while writing, even when the set is complete. */
    unsigned sequence = atomic_load_explicit(&eq->sequence, memory_order_relaxed);
    atomic_store_explicit(&eq->sequence, sequence + 1u, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    eq->shared = next;
    atomic_store_explicit(&eq->sequence, sequence + 2u, memory_order_release);
}

void dd_eq_process(DDEqualizer *eq, const AudioBufferList *input, AudioBufferList *output) {
    if (eq == NULL || output == NULL) return;

    /* Map output channels, silencing everything first. */
    float *outPtr[DD_MAX_CHANNELS];
    UInt32 outStride[DD_MAX_CHANNELS];
    int outChannels = 0;
    UInt32 outFrames = 0;
    int haveOutFrames = 0;
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer *buffer = &output->mBuffers[i];
        if (buffer->mData == NULL) continue;
        memset(buffer->mData, 0, buffer->mDataByteSize);
        UInt32 channels = buffer->mNumberChannels;
        if (channels == 0) continue;
        UInt32 frames = buffer->mDataByteSize / (UInt32)(sizeof(float) * channels);
        if (!haveOutFrames || frames < outFrames) {
            outFrames = frames;
            haveOutFrames = 1;
        }
        for (UInt32 c = 0; c < channels && outChannels < DD_MAX_CHANNELS; c++) {
            outPtr[outChannels] = (float *)buffer->mData + c;
            outStride[outChannels] = channels;
            outChannels++;
        }
    }

    /* Map input (tap) channels. */
    const float *inPtr[DD_MAX_CHANNELS];
    UInt32 inStride[DD_MAX_CHANNELS];
    int inChannels = 0;
    UInt32 inFrames = 0;
    int haveInFrames = 0;
    if (input != NULL) {
        for (UInt32 i = 0; i < input->mNumberBuffers; i++) {
            const AudioBuffer *buffer = &input->mBuffers[i];
            UInt32 channels = buffer->mNumberChannels;
            if (buffer->mData == NULL || channels == 0) continue;
            UInt32 frames = buffer->mDataByteSize / (UInt32)(sizeof(float) * channels);
            if (!haveInFrames || frames < inFrames) {
                inFrames = frames;
                haveInFrames = 1;
            }
            for (UInt32 c = 0; c < channels && inChannels < DD_MAX_CHANNELS; c++) {
                inPtr[inChannels] = (const float *)buffer->mData + c;
                inStride[inChannels] = channels;
                inChannels++;
            }
        }
    }

    if (outChannels == 0 || inChannels == 0) {
        dd_count_silence(eq, haveOutFrames ? outFrames : 0);
        return;
    }

    UInt32 frames = inFrames < outFrames ? inFrames : outFrames;
    dd_refresh_coefficients(eq);
    const DDCoefficients *k = &eq->current;
    float peak = 0.0f;
    unsigned write = atomic_load_explicit(&eq->ringWrite, memory_order_relaxed);

    for (UInt32 n = 0; n < frames; n++) {
        float mono = 0.0f;
        int monoCount = 0;
        for (int c = 0; c < outChannels; c++) {
            int source;
            if (c < inChannels) {
                source = c;
            } else if (inChannels == 1 && c == 1) {
                source = 0; /* a mono source feeds both speakers */
            } else {
                break; /* channels past the input stay silent */
            }

            float x = inPtr[source][n * inStride[source]];
            float magnitude = fabsf(x);
            if (magnitude > peak) peak = magnitude;

            double y = (double)x * (double)k->preamp;
            double (*z)[2] = eq->state[c];
            for (int b = 0; b < DD_EQ_BANDS; b++) {
                const DDBiquad *q = &k->bands[b];
                if (!q->active) continue;
                /* Transposed direct form II. */
                double out = q->b0 * y + z[b][0];
                z[b][0] = q->b1 * y - q->a1 * out + z[b][1];
                z[b][1] = q->b2 * y - q->a2 * out;
                y = out;
            }

            float result = dd_soft_limit((float)y);
            outPtr[c][n * outStride[c]] = result;
            if (c < 2) {
                mono += result;
                monoCount++;
            }
        }
        eq->ring[write & (DD_RING_SIZE - 1u)] = monoCount > 0 ? mono / (float)monoCount : 0.0f;
        write++;
    }
    atomic_store_explicit(&eq->ringWrite, write, memory_order_release);

    if (peak < DD_SILENCE_THRESHOLD) {
        dd_count_silence(eq, frames);
    } else {
        atomic_store_explicit(&eq->silentFrames, 0ull, memory_order_relaxed);
        atomic_store_explicit(&eq->heardAudio, 1, memory_order_relaxed);
    }
}

int dd_eq_copy_recent(DDEqualizer *eq, float *dest, int count) {
    if (eq == NULL || dest == NULL || count <= 0) return 0;
    if ((unsigned)count > DD_RING_SIZE) count = (int)DD_RING_SIZE;

    unsigned end = atomic_load_explicit(&eq->ringWrite, memory_order_acquire);
    unsigned available = end < (unsigned)count ? end : (unsigned)count;
    unsigned start = end - available;
    for (unsigned i = 0; i < available; i++) {
        dest[i] = eq->ring[(start + i) & (DD_RING_SIZE - 1u)];
    }
    return (int)available;
}

double dd_eq_silent_seconds(DDEqualizer *eq) {
    if (eq == NULL) return 0.0;
    unsigned long long frames = atomic_load_explicit(&eq->silentFrames, memory_order_relaxed);
    return (double)frames / eq->sampleRate;
}

int dd_eq_has_heard_audio(DDEqualizer *eq) {
    if (eq == NULL) return 0;
    return atomic_load_explicit(&eq->heardAudio, memory_order_relaxed);
}

/* ---- Capture for live transcription ---- */

#define DD_CAPTURE_SIZE 1048576u /* power of two: about 21 s at 48 kHz */

struct DDCapture {
    float ring[DD_CAPTURE_SIZE];
    atomic_ullong written;          /* total samples written; audio thread stores, reader loads */
    unsigned long long readPosition; /* reader only */
    atomic_int heardAudio;
};

DDCapture *dd_capture_create(void) {
    DDCapture *capture = calloc(1, sizeof(DDCapture));
    if (capture == NULL) return NULL;
    atomic_init(&capture->written, 0ull);
    atomic_init(&capture->heardAudio, 0);
    capture->readPosition = 0;
    return capture;
}

void dd_capture_destroy(DDCapture *capture) {
    free(capture);
}

void dd_capture_write(DDCapture *capture, const AudioBufferList *input, AudioBufferList *output) {
    if (output != NULL) {
        for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
            AudioBuffer *buffer = &output->mBuffers[i];
            if (buffer->mData != NULL) memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
    if (capture == NULL || input == NULL) return;

    const float *inPtr[DD_MAX_CHANNELS];
    UInt32 inStride[DD_MAX_CHANNELS];
    int inChannels = 0;
    UInt32 frames = 0;
    int haveFrames = 0;
    for (UInt32 i = 0; i < input->mNumberBuffers; i++) {
        const AudioBuffer *buffer = &input->mBuffers[i];
        UInt32 channels = buffer->mNumberChannels;
        if (buffer->mData == NULL || channels == 0) continue;
        UInt32 count = buffer->mDataByteSize / (UInt32)(sizeof(float) * channels);
        if (!haveFrames || count < frames) {
            frames = count;
            haveFrames = 1;
        }
        for (UInt32 c = 0; c < channels && inChannels < DD_MAX_CHANNELS; c++) {
            inPtr[inChannels] = (const float *)buffer->mData + c;
            inStride[inChannels] = channels;
            inChannels++;
        }
    }
    if (inChannels == 0 || frames == 0) return;

    unsigned long long write = atomic_load_explicit(&capture->written, memory_order_relaxed);
    float peak = 0.0f;
    for (UInt32 n = 0; n < frames; n++) {
        float sum = 0.0f;
        for (int c = 0; c < inChannels; c++) {
            sum += inPtr[c][n * inStride[c]];
        }
        float mono = sum / (float)inChannels;
        float magnitude = fabsf(mono);
        if (magnitude > peak) peak = magnitude;
        capture->ring[write & (DD_CAPTURE_SIZE - 1u)] = mono;
        write++;
    }
    atomic_store_explicit(&capture->written, write, memory_order_release);
    if (peak >= DD_SILENCE_THRESHOLD) {
        atomic_store_explicit(&capture->heardAudio, 1, memory_order_relaxed);
    }
}

int dd_capture_read(DDCapture *capture, float *dest, int maxCount) {
    if (capture == NULL || dest == NULL || maxCount <= 0) return 0;
    unsigned long long end = atomic_load_explicit(&capture->written, memory_order_acquire);
    unsigned long long start = capture->readPosition;
    /* Fell behind: skip to recent audio, leaving the writer half the ring of room. */
    if (end - start > DD_CAPTURE_SIZE / 2u) start = end - DD_CAPTURE_SIZE / 2u;
    unsigned long long available = end - start;
    if (available > (unsigned long long)maxCount) available = (unsigned long long)maxCount;
    for (unsigned long long i = 0; i < available; i++) {
        dest[i] = capture->ring[(start + i) & (DD_CAPTURE_SIZE - 1u)];
    }
    capture->readPosition = start + available;
    return (int)available;
}

int dd_capture_has_heard_audio(DDCapture *capture) {
    if (capture == NULL) return 0;
    return atomic_load_explicit(&capture->heardAudio, memory_order_relaxed);
}
