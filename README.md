# Voice Lab

Native macOS test app for recording your voice, speaking typed English, Tagalog, or Spanish text, and translating spoken English into Spanish in your saved voice. It runs locally and does not place calls or route audio into calls. The typed-text section reads text without translating it.

## Run

Open `build/Voice Lab.app`. Allow microphone access when you click Record, read the passage exactly, and stop. Preview the recording, type text, choose its language, then click **Generate in my voice**, then **Play generated audio**. Generated speech never plays automatically. A waveform displays the latest output and tracks playback.

This development app depends on this folder remaining in place. Quit with Cmd-Q.

## Speak English → hear Spanish

With a voice sample saved, click **Start speaking English**, say a short phrase, then click **Stop & translate**. The app shows recognized English, Spanish translation, and prepares Spanish in your cloned voice. Review the waveform and click **Play generated audio** to listen; click **Stop playback** to stop. Recording stops automatically at 30 seconds. This is a start/stop interaction, not continuous streaming.

The timing line measures Stop until generated audio is ready, plus worker recognition, translation, and synthesis timings. This excludes the time you spend speaking and does not include the time you wait before pressing Play or physical speaker latency. First-use processing may be slower.

English recognition uses faster-whisper base.en (CPU int8); translation uses Helsinki-NLP/opus-mt-en-es (CPU); speech uses OmniVoice (MLX). All models load locally before the controls become available. Additional model downloads total roughly 450 MB. Spoken phrases are stored as `.local-data/utterance.wav`, separate from your saved voice sample; each new phrase overwrites that file. No recordings are uploaded.

`translation_test.py` verified silence rejection, reference preservation, and two synthetic English recordings end to end: “Good morning” → “Buenos días” took 3.03 seconds; “Thank you” → “Gracias” took 2.44 seconds from worker request to generated WAV. These are fixture timings, not a guarantee for live microphone input. Results: `build/translation-test.json`.

## Setup / rebuild

Apple Silicon, macOS 15+, Python 3.12 and Xcode command-line tools.

```sh
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python download_model.py
zsh build.sh
```

The model download is about 2 GB. Generation forces Hugging Face and Transformers offline; no API key or hosted service is used. The app starts one Python child process and communicates through pipes, not a network listener.

Local files (ignored by Git): `.local-data/reference.wav` (accepted voice sample), `pending.wav` (latest attempted recording), `speech.wav` (latest output), and `engine.log` (diagnostics). No recordings are uploaded. Record again to replace the accepted sample. To erase all saved voice data, quit the app and remove `.local-data` in Finder.

Model: mlx-community/OmniVoice-bfloat16, Apache-2.0. Runtime: MLX Audio.
Voice likeness and latency must be evaluated with the user's own sample. Reference validation catches duration, quiet audio and substantial clipping; it does not verify that the spoken words match the passage.

## Verification

`smoke_test.py` uses a synthetic system-voice fixture and a temporary data directory to exercise offline English, Tagalog, and Spanish generation, silence rejection, and non-silent WAV output. It never replaces the saved user recording. Results are saved to `build/smoke-test.json`.

Tagalog is the default, mapped to OmniVoice’s Filipino (`fil`) language tag; Spanish uses `es` and English uses `en`. The existing English reading passage and recording remain usable for all three languages. Type text in the selected language; this app does not translate it.

Language coverage: https://github.com/k2-fsa/OmniVoice/blob/master/docs/languages.md
