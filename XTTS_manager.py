import sounddevice as sd
import numpy as np
from TTS.api import TTS as TTS_API
import re
import threading
import queue

class TTS:
    def __init__(self):
        self.tts = TTS_API(model_name="tts_models/en/ljspeech/tacotron2-DDC", progress_bar=False).to("cpu")
        self.sample_rate = self.tts.synthesizer.output_sample_rate
        self.audio_queue = queue.Queue()
        self.stop_signal = threading.Event()

    def speak(self, text: str):
        sentences = self._split_into_sentences(text)

        # Start audio playback thread
        audio_thread = threading.Thread(target=self._play_audio)
        audio_thread.start()

        # Generate audio in main thread
        for sentence in sentences:
            sentence = sentence.strip()
            if sentence:
                wav = self.tts.tts(sentence)
                wav_np = np.array(wav, dtype=np.float32)
                self.audio_queue.put(wav_np)

        # Signal end of playback
        self.audio_queue.put(None)  # Sentinel
        audio_thread.join()

    def _play_audio(self):
        while True:
            wav = self.audio_queue.get()
            if wav is None:  # Sentinel to stop
                break
            sd.play(wav, samplerate=self.sample_rate)
            sd.wait()

    def _split_into_sentences(self, text: str):
        sentence_pattern = r'(?<!\w\.\w.)(?<![A-Z][a-z]\.)(?<=\.|\!|\?)\s+'
        return re.split(sentence_pattern, text)
