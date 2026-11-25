# Voice listener

An always-on ambient voice daemon for the claude_memory system: it transcribes the room, tags each
utterance with the speaker's voice, writes percepts into the memory database, answers when addressed
("Claude, ..."), notices salient moments with a small background brain, and queues spoken work
requests into `voice_tasks` for a main session to pick up. Raw audio never touches disk; only text
reaches the database.

`src\` here is a **template**, like everything else in this repo: `{{USER_NAME}}` /
`{{USER_NAME_LOWER}}` and the path tokens are filled on install. `install.ps1` renders the source
into `C:\Tools\listener` (`-ListenerRoot` to move it), seeds `listener.json` from the template once
(then never overwrites it), and builds `bin\Listener.exe` when the dotnet SDK is present; pass
`-RegisterListenerTask` to also create and start the at-logon task, or `-SkipListener` to leave the
listener out entirely. Steps 1, 3 and 5 below are what install.ps1 automates -- the models (step 2)
and voice enrollment (step 4) are always manual.

## What is deliberately NOT in the repo

- **`models\`** (~1.9 GB of ONNX/GGML binaries) -- fetch per the table below, or copy the folder
  from a machine that already runs the listener.
- **`voices\`** (enrolled voiceprints) -- personal biometrics, and they encode each machine's own
  microphone anyway. Re-enroll on every machine.
- **`listener.json`** -- its `Prompt` carries personal names and project jargon. Start from
  `listener.template.json`.

## Setup

1. Fill the tokens: copy `src\` to `C:\Tools\listener\src`, replacing `{{USER_NAME}}` with your
   name (e.g. `Damian`), `{{USER_NAME_LOWER}}` with its lowercase (`damian`), and the path tokens
   with their values (`{{DB_PATH_WIN}}` -> the memory database path). Copy
   `listener.template.json` to `C:\Tools\listener\listener.json` and fill it the same way; put the
   names and jargon you want transcribed correctly in `Prompt` (used by the Whisper engine only).
2. Models into `C:\Tools\listener\models` (easiest: copy the whole folder from an existing machine):

   | Path | What | Source |
   |---|---|---|
   | `parakeet\` (631 MB) | Speech-to-text: NVIDIA Parakeet TDT 0.6B v2, int8 | [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2) -- extract so `encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt` sit directly in `parakeet\` |
   | `ggml-silero-v6.2.0.bin` (1 MB) | Voice activity detection | [ggml-org/whisper-vad on Hugging Face](https://huggingface.co/ggml-org/whisper-vad) |
   | `ggml-large-v3-turbo-q5_0.bin` (548 MB) | Optional alternate STT: Whisper (`"Model": "ggml-large-v3-turbo-q5_0.bin"`) | [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) |
   | `wespeaker_en_voxceleb_resnet34_LM.onnx` (26 MB) | Speaker voiceprints | [sherpa-onnx speaker-embedding models](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models) |
   | `kokoro\` (384 MB) | Text-to-speech (Kokoro v1.0, 54 voices) | [sherpa-onnx TTS models](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models) (kokoro-en-v1.0) |
   | `minilm\` (87 MB) | Sentence embeddings (salience novelty + addressee) | all-MiniLM-L6-v2 ONNX export + `vocab.txt` |
   | `yamnet\` (16 MB) | Non-speech sound labels | YAMNet ONNX export + `yamnet_class_map.csv` |

3. Build and install:

   ```powershell
   dotnet publish C:\Tools\listener\src -c Release -o C:\Tools\listener\bin
   ```

4. Enroll voices (read the sentences it prompts; ~30 s each). One fingerprint per microphone --
   `Identify` scores against all of them and takes the best:

   ```powershell
   C:\Tools\listener\bin\Listener.exe enroll <your lowercase name>
   C:\Tools\listener\bin\Listener.exe enroll <name> <mic-variant>     # e.g. "laptop"
   C:\Tools\listener\bin\Listener.exe enroll-tts claude               # its own TTS voice, digitally
   ```

5. Run it as a scheduled task at logon:

   ```powershell
   schtasks /create /tn ClaudeListener /tr C:\Tools\listener\bin\Listener.exe /sc onlogon /rl limited
   schtasks /run /tn ClaudeListener
   ```

   Logs land in `C:\Tools\listener\logs\listener_YYYYMM.log`. Redeploys must stop the daemon first
   (`schtasks /end /tn ClaudeListener` + `Stop-Process -Name Listener`), or publish fails with the
   executable locked.

## Settings worth knowing

- `Model`: `"parakeet"` (a folder = sherpa-onnx NeMo transducer; does not hallucinate, no prompt
  biasing) or a `ggml-*.bin` file (= Whisper; honors `Prompt`, hallucinates on junk audio).
- `AddresseeMode`: start in `"shadow"` -- the wake word always works, while the learned
  am-I-being-addressed detector trains silently from real exchanges; flip to `"live"` once its
  logged shadow scores look right.
- `SpeakerThreshold` 0.72 is the match bar; `SpeakerStick*` keeps a far-field monologue from
  flip-flopping between named and `other`; `SpeakerSplit*` cuts a stretch where the voice changes
  mid-stretch.
- The self-hearing protections (it leaves the mic open while speaking, for barge-in) are not
  settings: while its TTS plays plus a 4 s echo tail, anything scoring close to its own voiceprint
  is tagged `claude` and never answered.
