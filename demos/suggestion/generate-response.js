const https = require('https');
const { URL } = require('url');
const phrases = require('./phrases');

const DEFAULT_MODEL = 'gpt-4o-mini';
const DEFAULT_URL = 'https://api.openai.com/v1/chat/completions';

const apiUrl = process.env.SUGGEST_API_URL || DEFAULT_URL;
const apiKey = process.env.SUGGEST_API_KEY;
const model = process.env.SUGGEST_MODEL || DEFAULT_MODEL;
const allowInsecureTls = (process.env.SUGGEST_INSECURE_SKIP_VERIFY || 'true').toLowerCase() !== 'false';

function pickRandom(items) {
  return items[Math.floor(Math.random() * items.length)];
}

function postJson(urlString, body, extraHeaders = {}) {
  const url = new URL(urlString);
  const payload = JSON.stringify(body);

  const options = {
    method: 'POST',
    hostname: url.hostname,
    port: url.port || (url.protocol === 'https:' ? 443 : 80),
    path: `${url.pathname}${url.search}`,
    agent: allowInsecureTls ? new https.Agent({ rejectUnauthorized: false }) : undefined,
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload),
      ...extraHeaders
    }
  };

  return new Promise((resolve, reject) => {
    const req = https.request(options, res => {
      const chunks = [];

      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        const responseBody = Buffer.concat(chunks).toString('utf8');

        if (res.statusCode < 200 || res.statusCode >= 300) {
          return reject(new Error(`API error: ${res.statusCode} ${res.statusMessage} - ${responseBody}`));
        }

        try {
          resolve(JSON.parse(responseBody));
        } catch (parseError) {
          reject(new Error(`Failed to parse API response: ${parseError.message} - ${responseBody}`));
        }
      });
    });

    req.on('error', reject);
    req.setTimeout(20000, () => {
      req.destroy(new Error('Request timed out'));
    });

    req.write(payload);
    req.end();
  });
}

async function askForResponse(selectedPhrase) {
  if (!apiKey) {
    throw new Error('Set SUGGEST_API_KEY in your environment before running this demo.');
  }

  const prompt = `Phrase: ${selectedPhrase.script}\nLanguage: ${selectedPhrase.language}\nRomanized pronunciation: ${selectedPhrase.romanized}\nMeaning: ${selectedPhrase.meaning}`;

  const body = {
    model,
    messages: [
      {
        role: 'system',
        content: 'You help English speakers reply to multilingual casual phrases. Respond with a short reply written phonetically using the roman alphabet, followed by a newline and its English meaning.'
      },
      {
        role: 'user',
        content: `${prompt}\n\nGenerate a suggested response for this sentence typed phonetically in the roman alphabet, and include the meaning of your response in English.`
      }
    ],
    temperature: 0.7
  };

  const data = await postJson(apiUrl, body, {
    Authorization: `Bearer ${apiKey}`
  });
  const content = data?.choices?.[0]?.message?.content?.trim();

  if (!content) {
    throw new Error('API response missing content.');
  }

  return content;
}

async function main() {
  const selectedPhrase = pickRandom(phrases);
  console.log(`Selected phrase: ${selectedPhrase.script} (${selectedPhrase.language})`);
  console.log('');

  try {
    const apiStartTime = Date.now();
    const suggestedResponse = await askForResponse(selectedPhrase);
    const elapsedSeconds = ((Date.now() - apiStartTime) / 1000).toFixed(2);

    console.log(`Suggested response: ${suggestedResponse}`);
    console.log('');
    console.log(`Time to complete: ${elapsedSeconds}s`);
  } catch (error) {
    console.error('Failed to generate suggested response:', error.message);
    process.exitCode = 1;
  }
}

main();
