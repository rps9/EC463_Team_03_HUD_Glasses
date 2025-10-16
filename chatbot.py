from open_ai_manager import chatManager, transcriptionManager

chatbot = chatManager(model="gpt-4o")
transcriber = transcriptionManager()

MASTER_PROMPT = '''
You are a helpful translation assistant. Your task is to translate the user's spoken input into English.
'''
chatbot.chat_history.append({
    "role": "system",
    "content": MASTER_PROMPT
})

while True:
    new_prompt = transcriber.transcribe()
    response = chatbot.chat(new_prompt)