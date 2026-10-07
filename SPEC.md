# Voice Lab — native macOS experiment

User-authorized scope: record the user's voice while they read a supplied English passage, then synthesize typed English, Tagalog, or Spanish text in a similar voice, locally on this Mac.

Native SwiftUI macOS window; AVAudioRecorder for microphone recording and AVAudioPlayer for preview/playback. A persistent Python child process runs OmniVoice bfloat16 with MLX. Communication uses stdin/stdout JSON, not a web server. Model download is a setup step; runtime uses offline model loading. No cloud voice API, call integration, or automatic calls.

Tagalog is the default, using the model’s Filipino (`fil`) language tag. Preserve the existing English reference recording and transcript.

Flow: record 5–30 seconds, stop, preview, type text, choose language, generate, then explicitly play. Show loading/generating/error status. A new recording replaces the previous sample only after validation. Disable conflicting actions while recording/generating. Never use a generic voice as a hidden fallback.

Storage: ignored `.local-data/` for reference WAV, generated WAV, and worker diagnostics; ignored `.models/`, `.venv/`, `build/` for machine-local artifacts. Files stay local. This is a source-linked development app, not a distributable standalone installer.

Verification: compile native app; load local model; generate real WAV from a clearly labeled synthetic fixture to validate the pipeline; validate sample duration/level rejection; open the actual app and inspect controls. User's voice likeness can only be assessed after they record themselves. Report synthesis timing without promising realtime call performance.

## English → Spanish speech test

Add a separate short-utterance recorder, started and stopped explicitly by the user (push-to-talk with a keyboard-accessible start/stop button). Save to `utterance.wav`, never replace the cloned-voice reference. Accept 0.3–30 seconds; reject silence. Transcribe English with local faster-whisper base.en, translate with local Helsinki-NLP opus-mt-en-es, and synthesize Spanish with the existing saved voice. Load models before enabling the test. Keep typed English/Spanish/Tagalog synthesis available.

Show recognized English, Spanish translation, recognition/translation/synthesis timings, and elapsed time from Stop until audio is ready. Generate only after Stop, not continuously. Generated audio never plays automatically. Display the latest generated WAV as a real amplitude waveform with duration, playback progress, and a Play/Stop button. Reset the waveform when starting a new generation and restore the last saved output when reopening. Runtime remains offline. This test plays through Mac output; it does not route to or place a call.
