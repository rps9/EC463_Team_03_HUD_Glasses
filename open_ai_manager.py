from openai import OpenAI
import tiktoken
import os
from dotenv import load_dotenv
from rich import print
import io
import sounddevice as sd
import soundfile as sf
import threading
import sys
import numpy as np

def num_tokens_from_messages(messages, model):
    '''
    Returns the number of tokens used by a list of messages.
    '''
    try:
        encoding = tiktoken.encoding_for_model(model)
        num_tokens = 0
        for message in messages:
            num_tokens += 4  # every message follows <im_start>{role/name}\n{content}<im_end>\n
            for key, value in message.items():
                num_tokens += len(encoding.encode(value))
                if key == "name":  # if there's a name, the role is omitted
                    num_tokens += -1  # role is always required and always 1 token
        num_tokens += 2  # every reply is primed with <im_start>assistant
        return num_tokens
    except Exception:
        raise NotImplementedError(f"""num_tokens_from_messages() is not presently implemented for model {model}.
        #See https://github.com/openai/openai-python/blob/main/chatml.md for information on how messages are converted to tokens.""")
      

class chatManager:
    
    def __init__(self, model="gpt-4o"):
        load_dotenv()
        self.chat_history = [] # Stores the entire conversation
        self.model = model # Set the model
        try:
            self.client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))
        except TypeError:
            exit("Oops! You forgot to set OPENAI_API_KEY in your environment!")

    # Asks a question with no chat history
    def chat(self, prompt=""):
        if not prompt:
            print("Didn't receive input!")
            return

        # Check that the prompt is under the token context limit
        chat_question = [{"role": "user", "content": prompt}]
        if num_tokens_from_messages(chat_question, self.model) > 8000:
            print("The length of this chat question is too large for the GPT model")
            return

        print("[yellow]\nAsking ChatGPT a question...")
        completion = self.client.chat.completions.create(
          model=self.model,
          messages=chat_question
        )

        # Process the answer
        openai_answer = completion.choices[0].message.content
        print(f"[green]\n{openai_answer}\n")
        return openai_answer

    # Asks a question that includes the full conversation history
    def chat_with_history(self, prompt=""):
        if not prompt:
            print("Didn't receive input!")
            return

        # Add our prompt into the chat history
        self.chat_history.append({"role": "user", "content": prompt})

        # Check total token limit. Remove old messages as needed
        print(f"[coral]Chat History has a current token length of {num_tokens_from_messages(self.chat_history, self.model)}")
        while num_tokens_from_messages(self.chat_history, self.model) > 8000:
            self.chat_history.pop(1) # We skip the 1st message since it's the system message
            print(f"Popped a message! New token length is: {num_tokens_from_messages(self.chat_history, self.model)}")

        print("[yellow]\nAsking ChatGPT a question...")
        completion = self.client.chat.completions.create(
          model=self.model,
          messages=self.chat_history
        )

        # Add this answer to our chat history
        self.chat_history.append({"role": completion.choices[0].message.role, "content": completion.choices[0].message.content})

        # Process the answer
        openai_answer = completion.choices[0].message.content
        print(f"[green]\n{openai_answer}\n")
        return openai_answer

class transcriptionManager:
    def __init__(self):
        load_dotenv()
        self.client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))
    
    def transcribe(self, samplerate: int = 16000):
        """
        Record from the default microphone at `samplerate` Hz.
        Press Enter to start recording, press Enter again to stop.
        Send the recording to whisper-1 and return the transcription.
        """
        print("[yellow]Press Enter to start recording...")
        input()
        
        print("[yellow]Recording... Press Enter to stop recording.")
        
        # Start recording in a separate thread
        recording_data = []
        stop_recording = threading.Event()
        
        def record_audio():
            with sd.InputStream(samplerate=samplerate, channels=1, callback=lambda indata, frames, time, status: recording_data.extend(indata.copy())):
                stop_recording.wait()
        
        # Start recording thread
        recording_thread = threading.Thread(target=record_audio)
        recording_thread.start()
        
        # Wait for Enter key to stop recording
        input()
        stop_recording.set()
        recording_thread.join()
        
        print("[yellow]Recording stopped. Processing audio...")
        
        # Convert recording data to numpy array
        recording = np.array(recording_data)
        
        # write to an in-memory WAV file
        wav_buffer = io.BytesIO()
        sf.write(wav_buffer, recording, samplerate, format="wav")
        wav_buffer.name = "mic_input.wav"  # whisper API uses the extension to infer format
        wav_buffer.seek(0)

        print("[yellow]Processing mic audio…")
        transcript = (
            self.client.audio.transcriptions.create(
                model="whisper-1",
                file=wav_buffer
            )
            .text
        )
        print(f"[green]\n[Transcription] {transcript}\n")
        return transcript



if __name__ == '__main__':
    openai_manager = chatManager()

    # CHAT TEST
    chat_without_history = openai_manager.chat("Hey ChatGPT what is 2 + 2? But tell it to me as Yoda")

    # CHAT WITH HISTORY TEST
    FIRST_SYSTEM_MESSAGE = {"role": "system", "content": "Act like you are Captain Jack Sparrow from the Pirates of Carribean movie series!"}
    FIRST_USER_MESSAGE = {"role": "user", "content": "Ahoy there! Who are you, and what are you doing in these parts? Please give me a 1 sentence background on how you got here."}
    openai_manager.chat_history.append(FIRST_SYSTEM_MESSAGE)
    openai_manager.chat_history.append(FIRST_USER_MESSAGE)

    while True:
        new_prompt = input("\nType out your next question Jack Sparrow, then hit enter: \n\n")
        openai_manager.chat_with_history(new_prompt)
        