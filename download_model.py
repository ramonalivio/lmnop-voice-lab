from pathlib import Path
import os

ROOT = Path(__file__).resolve().parent
os.environ['HF_HOME'] = str(ROOT / '.models' / 'hub')
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
from huggingface_hub import snapshot_download

snapshot_download('mlx-community/OmniVoice-bfloat16', local_dir=ROOT / '.models' / 'omnivoice', max_workers=4)
snapshot_download('Systran/faster-whisper-base.en', local_dir=ROOT / '.models' / 'whisper-base-en', max_workers=4)
snapshot_download('Helsinki-NLP/opus-mt-en-es', local_dir=ROOT / '.models' / 'translate-en-es', allow_patterns=['*.json', '*.spm', 'pytorch_model.bin', '*.safetensors'], max_workers=4)
print('Model downloaded.')
