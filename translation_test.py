"""Real offline speech translation using synthetic fixtures, never user recordings."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf
from worker import PROMPT, validate

ROOT = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='voice-lab-translation-') as directory:
    path = Path(directory)
    def fixture(name, text):
        aiff = path / (name + '.aiff')
        subprocess.run(['/usr/bin/say', '-v', 'Samantha', '-o', str(aiff), text], check=True)
        audio, sr = sf.read(aiff)
        sf.write(path / (name + '.wav'), audio, sr)

    fixture('reference', PROMPT)
    original = hashlib.sha256((path / 'reference.wav').read_bytes()).hexdigest()
    env = dict(os.environ, VOICE_LAB_TEST_DATA=str(path))
    child = subprocess.Popen([sys.executable, '-u', str(ROOT / 'worker.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    events = []
    def receive(terminal):
        while True:
            line = child.stdout.readline()
            assert line, 'Worker exited unexpectedly'
            event = json.loads(line)
            print(line, end='', flush=True)
            events.append(event)
            assert event['event'] != 'fatal', event
            if event['event'] in terminal:
                return event
    def request():
        child.stdin.write(json.dumps({'action': 'translate_speech'}) + '\n')
        child.stdin.flush()
    try:
        receive({'ready'})
        # Silence must not hallucinate or produce speech.
        sf.write(path / 'utterance.wav', np.zeros(24000), 24000)
        request()
        assert 'quiet' in receive({'error', 'generated'})['message']
        for phrase, expected in [('Good morning.', 'buenos'), ('Thank you.', 'gracias')]:
            fixture('utterance', phrase)
            request()
            result = receive({'generated', 'error'})
            assert result['event'] == 'generated', result
            translation = next(e['translation'] for e in reversed(events) if e['event'] == 'translation')
            assert expected in translation.lower(), translation
            audio, sr = sf.read(path / 'speech.wav')
            assert len(audio) / sr > 0.3 and np.isfinite(audio).all() and np.max(np.abs(audio)) > 0.01
        assert hashlib.sha256((path / 'reference.wav').read_bytes()).hexdigest() == original
        (ROOT / 'build' / 'translation-test.json').write_text(json.dumps(events, indent=2))
        print('PASS: silence rejected, English recognized, Spanish translated and synthesized, reference preserved.')
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
