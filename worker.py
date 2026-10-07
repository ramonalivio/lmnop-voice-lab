"""Local-only JSON-lines worker. stdout is protocol; library diagnostics use stderr."""
import contextlib
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get('VOICE_LAB_TEST_DATA', str(ROOT / '.local-data')))
DATA.mkdir(exist_ok=True, mode=0o700)
os.environ['HF_HOME'] = str(ROOT / '.models' / 'hub')
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
PROMPT = "Today I am testing my own voice. I would like to speak clearly and naturally, at a comfortable pace. Tomorrow, I plan to call a friend and talk about our plans for the weekend."

def emit(**event):
    print(json.dumps(event), file=sys.__stdout__, flush=True)

def validate(path, utterance=False):
    import numpy as np
    import soundfile as sf
    audio, sr = sf.read(path, dtype='float32', always_2d=True)
    duration = len(audio) / sr
    if utterance and not 0.3 <= duration <= 31:
        raise ValueError('Speak for between 0.3 and 30 seconds, then press Stop.')
    if not utterance and not 5 <= duration <= 31:
        raise ValueError('Please record between 5 and 30 seconds, reading the entire passage.')
    if not np.isfinite(audio).all() or float(np.sqrt(np.mean(audio ** 2))) < 0.002:
        raise ValueError('The recording is too quiet. Check your microphone and try again.')
    if float(np.mean(np.abs(audio) > 0.995)) > 0.02:
        raise ValueError('The recording is distorted. Move a little farther from the microphone.')
    return audio.mean(axis=1), sr, duration

def main():
    emit(event='loading', message='Loading your local voice model…')
    try:
        with contextlib.redirect_stdout(sys.stderr):
            import numpy as np
            import soundfile as sf
            from mlx_audio.tts.utils import load_model
            model = load_model(str(ROOT / '.models' / 'omnivoice'))
            emit(event='loading', message='Loading offline English recognition and Spanish translation…')
            from faster_whisper import WhisperModel
            import torch
            from transformers import MarianMTModel, MarianTokenizer
            torch.set_num_threads(4)
            recognizer = WhisperModel(str(ROOT / '.models' / 'whisper-base-en'), device='cpu', compute_type='int8', cpu_threads=4, local_files_only=True)
            translation_path = str(ROOT / '.models' / 'translate-en-es')
            translator_tokenizer = MarianTokenizer.from_pretrained(translation_path, local_files_only=True)
            translator = MarianMTModel.from_pretrained(translation_path, local_files_only=True).eval()
        emit(event='ready', message='Voice model ready. Record the passage to begin.')
    except Exception as exc:
        emit(event='fatal', message=str(exc))
        return
    for line in sys.stdin:
        try:
            request = json.loads(line)
            action = request.get('action')
            if action == 'reference':
                audio, sr, duration = validate(DATA / 'pending.wav')
                sf.write(DATA / 'reference.wav', audio, sr, subtype='PCM_16')
                emit(event='reference', duration=duration, message='Your voice sample is ready.')
            elif action in ('generate', 'translate_speech'):
                pipeline_started = time.monotonic()
                timings = {}
                text = request.get('text', '').strip()
                language = request.get('language', 'Tagalog')
                if action == 'translate_speech':
                    validate(DATA / 'reference.wav')
                    validate(DATA / 'utterance.wav', utterance=True)
                    emit(event='transcribing', message='Recognizing your English…')
                    stage = time.monotonic()
                    with contextlib.redirect_stdout(sys.stderr):
                        segments, _ = recognizer.transcribe(str(DATA / 'utterance.wav'), language='en', beam_size=3, vad_filter=True, vad_parameters={'min_silence_duration_ms': 300}, condition_on_previous_text=False)
                        transcript = ' '.join(s.text.strip() for s in segments if s.no_speech_prob < 0.6).strip()
                    timings['recognition'] = round(time.monotonic() - stage, 3)
                    if not transcript:
                        raise ValueError('No clear speech detected. Try again closer to the microphone.')
                    if len(transcript) > 600:
                        raise ValueError('Please try a shorter English phrase.')
                    emit(event='transcript', transcript=transcript, message='Translating English to Spanish…')
                    stage = time.monotonic()
                    with contextlib.redirect_stdout(sys.stderr), torch.inference_mode():
                        tokens = translator_tokenizer(transcript, return_tensors='pt')
                        translated = translator.generate(**tokens, max_new_tokens=256, num_beams=3)
                        text = translator_tokenizer.decode(translated[0], skip_special_tokens=True).strip()
                    timings['translation'] = round(time.monotonic() - stage, 3)
                    language = 'Spanish'
                    emit(event='translation', translation=text, message='Speaking the Spanish translation in your voice…')
                if not text or len(text) > 600:
                    raise ValueError('Enter between 1 and 600 characters.')
                if language not in ('English', 'Tagalog', 'Spanish'):
                    raise ValueError('Choose English, Tagalog, or Spanish.')
                validate(DATA / 'reference.wav')
                emit(event='generating', message='Generating speech in your voice…')
                started = time.monotonic()
                with contextlib.redirect_stdout(sys.stderr):
                    parts = []
                    sample_rate = model.sample_rate
                    for result in model.generate(text=text, language={'English': 'en', 'Tagalog': 'fil', 'Spanish': 'es'}[language], ref_audio=str(DATA / 'reference.wav'), ref_text=PROMPT, ref_audio_max_duration_s=31.0):
                        parts.append(np.asarray(result.audio))
                        sample_rate = result.sample_rate
                    if not parts:
                        raise ValueError('The model returned no audio. Try a shorter sentence.')
                    audio = np.concatenate(parts)
                    if not np.isfinite(audio).all() or np.max(np.abs(audio)) < 0.0001:
                        raise ValueError('The generated audio was invalid. Try again.')
                    sf.write(DATA / 'speech.wav', audio, sample_rate, subtype='PCM_16')
                elapsed = time.monotonic() - started
                timings['synthesis'] = round(elapsed, 3)
                emit(event='generated', mode=action, timings=timings, total=round(time.monotonic()-pipeline_started, 3), seconds=round(elapsed, 2), duration=round(len(audio)/sample_rate, 2), message=f'Ready — generated in {elapsed:.1f} seconds.')
            else:
                raise ValueError('Unknown request.')
        except Exception as exc:
            emit(event='error', message=str(exc))

if __name__ == '__main__':
    main()
