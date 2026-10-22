#ifndef DEVDOCK_DSP_H
#define DEVDOCK_DSP_H

#include <CoreAudio/CoreAudioTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DD_EQ_BANDS 10

/// A 10-band equalizer (peaking filters at 31 Hz to 16 kHz, wider at the two ends), with a
/// preamp and a soft limiter. Create and configure it on the main thread.
/// dd_eq_process runs on the audio thread and never allocates or locks.
typedef struct DDEqualizer DDEqualizer;

DDEqualizer *dd_eq_create(double sampleRate);
void dd_eq_destroy(DDEqualizer *eq);

/// Main thread. gainsDB holds DD_EQ_BANDS values in dB. The audio thread picks up the new
/// coefficients at the start of its next callback.
void dd_eq_set_gains(DDEqualizer *eq, const float *gainsDB, float preampDB);

/// Audio thread. Reads 32-bit float input and writes 32-bit float output, interleaved or not.
/// Output channels beyond the input's channel count are silenced (a mono input feeds two).
void dd_eq_process(DDEqualizer *eq, const AudioBufferList *input, AudioBufferList *output);

/// Main thread. Copies the most recent `count` processed mono samples, oldest first, into
/// dest. Returns how many were copied (fewer than count until enough audio has played).
int dd_eq_copy_recent(DDEqualizer *eq, float *dest, int count);

/// Main thread. Seconds of unbroken silence on the input, for the permission watchdog.
double dd_eq_silent_seconds(DDEqualizer *eq);

/// Main thread. 1 once any non-silent input has arrived, else 0.
int dd_eq_has_heard_audio(DDEqualizer *eq);

/// A mono capture buffer for live transcription: the audio thread writes what a tap hears,
/// one reader drains it. About 20 seconds at 48 kHz; a reader that falls further behind skips
/// ahead to recent audio.
typedef struct DDCapture DDCapture;

DDCapture *dd_capture_create(void);
void dd_capture_destroy(DDCapture *capture);

/// Audio thread. Mixes the input down to mono and stores it. Silences the output, if any.
void dd_capture_write(DDCapture *capture, const AudioBufferList *input, AudioBufferList *output);

/// Reader thread. Copies up to maxCount samples not read yet, oldest first. Returns the count.
int dd_capture_read(DDCapture *capture, float *dest, int maxCount);

/// Any thread. 1 once any non-silent input has arrived, else 0.
int dd_capture_has_heard_audio(DDCapture *capture);

#ifdef __cplusplus
}
#endif

#endif
