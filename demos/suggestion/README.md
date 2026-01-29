# Suggested Response Demo

Node.js script that keeps a small multilingual phrase bank (Spanish, Chinese, Hebrew), picks one at random, and asks a chat completion API to suggest a phonetic reply plus its English meaning. Output stays in the terminal.

## Setup

1. **Install dependencies**: none beyond Node 18+ (native `fetch`).
2. **Configure auth**. Either replace the `FALLBACK_API_KEY` placeholder in `generate-response.js` or export environment variables:

   ```bash
   export SUGGEST_API_KEY="<your-api-key>"
   export SUGGEST_API_URL="https://api.openai.com/v1/chat/completions" # optional override
   export SUGGEST_MODEL="gpt-4o-mini"                                # optional override
   ```

   For offline testing, you can skip the key and instead set `MOCK_RESPONSE="phonetic reply\nEnglish meaning"`. TLS checks are skipped by default; set `SUGGEST_INSECURE_SKIP_VERIFY=false` if you prefer strict verification.

## Run

```bash
node generate-response.js
```

Sample output format:

```
Selected phrase: ¿Hola, cómo estás? (Spanish)

Suggested response: Bien, y tú?
Fine, and you?

Time to complete: 0.71s
```

## How it works

- `phrases.js` defines 15 casual phrases (5 per language) with their romanized pronunciation and English meaning.
- `generate-response.js` chooses a phrase, builds the chat prompt, and posts it to the configured API.
- Timing is measured around the entire operation and printed as `Time to complete`.
