'use strict';

/**
 * Blitztext-Proxy
 *
 * Sitzt zwischen der Blitztext-App und den KI-APIs (OpenAI + fal.ai).
 * Die App schickt ihre Anfragen mit dem APP-PASSWORT als Bearer-Token.
 * Dieser Proxy prueft das Passwort, tauscht es gegen den echten API-Key
 * und leitet die Anfrage weiter. Die echten Keys verlassen den Server nie
 * und landen nie auf den Macs.
 *
 * Routen:
 *   POST /v1/audio/transcriptions   -> OpenAI Whisper (Diktat)
 *   POST /v1/chat/completions       -> OpenAI Chat (Textverbesserer, Zusammenfassung)
 *   POST /v1/meeting/transcriptions -> fal.ai Scribe v2 (Meeting mit Sprechern)
 *        Body: rohe m4a-Bytes. Query: ?language=deu&keyterms=a,b,c
 *        Der Proxy submitted an die fal-Queue, pollt bis zum Ergebnis und
 *        gibt das fal-JSON (text, words mit speaker_id) zurueck.
 *
 * Bewusst ohne externe Abhaengigkeiten: nur Node-Builtins.
 *
 * Logt KEINE Anfrage-Inhalte (kein Audio, kein Text). Nur Methode, Pfad,
 * Status und Dauer.
 */

const http = require('http');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '3020', 10);
const { OPENAI_API_KEY, FAL_API_KEY } = process.env;

// Ein Passwort pro Nutzer: APP_PASSWORD (= Nutzer "default") plus
// APP_PASSWORD_<NAME> (z. B. APP_PASSWORD_ANNA). So lassen sich einzelne
// Nutzer wieder abklemmen und das Log zeigt, wer was verbraucht.
const USER_PASSWORDS = {};
if (process.env.APP_PASSWORD) USER_PASSWORDS.default = process.env.APP_PASSWORD;
for (const [key, value] of Object.entries(process.env)) {
  const m = /^APP_PASSWORD_([A-Z0-9]+)$/.exec(key);
  if (m && value) USER_PASSWORDS[m[1].toLowerCase()] = value;
}
const OPENAI_BASE = 'https://api.openai.com';
const MAX_BODY = 64 * 1024 * 1024; // 64 MB (Meetings bis ~2h; OpenAI-Diktate bleiben klein)

const FAL_SUBMIT_URL = 'https://queue.fal.run/fal-ai/elevenlabs/speech-to-text/scribe-v2';
const FAL_POLL_INTERVAL_MS = 3000;
const FAL_POLL_TIMEOUT_MS = 8 * 60 * 1000; // muss unter dem nginx read timeout (600s) bleiben

// Nur diese OpenAI-Endpunkte werden 1:1 weitergeleitet. Alles andere wird
// abgewiesen, damit der Key nicht fuer beliebige Aufrufe missbraucht werden kann.
const ALLOWED_OPENAI_PATHS = new Set([
  '/v1/audio/transcriptions',
  '/v1/chat/completions',
]);

const MEETING_PATH = '/v1/meeting/transcriptions';

if (!OPENAI_API_KEY || Object.keys(USER_PASSWORDS).length === 0) {
  console.error('FATAL: OPENAI_API_KEY und mindestens ein APP_PASSWORD muessen in der Umgebung gesetzt sein (.env).');
  process.exit(1);
}
if (!FAL_API_KEY) {
  console.warn('WARNUNG: FAL_API_KEY fehlt - Meeting-Transkription ist deaktiviert.');
}

// Vergleich konstanter Laufzeit, damit das Passwort nicht ueber die
// Antwortzeit erraten werden kann. Hash beider Seiten gleicht Laengen aus.
// Liefert den Nutzernamen oder null.
function identifyUser(provided) {
  if (typeof provided !== 'string' || provided.length === 0) return null;
  const a = crypto.createHash('sha256').update(provided).digest();
  let matched = null;
  for (const [name, password] of Object.entries(USER_PASSWORDS)) {
    const b = crypto.createHash('sha256').update(password).digest();
    if (crypto.timingSafeEqual(a, b)) matched = name; // keine fruehe Rueckkehr: konstante Laufzeit
  }
  return matched;
}

function extractBearer(req) {
  const h = req.headers['authorization'] || '';
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? m[1].trim() : null;
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('PAYLOAD_TOO_LARGE'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// fal.ai akzeptiert je nach Key-Typ 'Key' oder 'Bearer' als Auth-Schema.
// Wir merken uns, was funktioniert.
let falAuthScheme = 'Key';

async function falFetch(url, options = {}) {
  const doFetch = (scheme) => fetch(url, {
    ...options,
    headers: { ...(options.headers || {}), 'Authorization': `${scheme} ${FAL_API_KEY}` },
  });
  let resp = await doFetch(falAuthScheme);
  if (resp.status === 401 || resp.status === 403) {
    const other = falAuthScheme === 'Key' ? 'Bearer' : 'Key';
    const retry = await doFetch(other);
    if (retry.status !== 401 && retry.status !== 403) {
      falAuthScheme = other;
      console.log(`fal auth scheme -> ${other}`);
    }
    return retry;
  }
  return resp;
}

async function handleMeetingTranscription(req, res, body, log) {
  if (!FAL_API_KEY) {
    sendJson(res, 503, { error: { message: 'Meeting-Transkription ist auf dem Server nicht konfiguriert' } });
    log(503);
    return;
  }
  if (body.length === 0) {
    sendJson(res, 400, { error: { message: 'Leerer Audio-Body' } });
    log(400);
    return;
  }

  const query = new URL(req.url, 'http://localhost').searchParams;
  const language = query.get('language') || 'deu';

  const payload = {
    audio_url: `data:audio/mp4;base64,${body.toString('base64')}`,
    diarize: true,
    tag_audio_events: false,
    language_code: language,
  };
  const keyterms = query.get('keyterms');
  if (keyterms) {
    payload.keyterms = keyterms.split(',').map((s) => s.trim()).filter(Boolean).slice(0, 100);
  }

  console.log(`meeting: ${Math.round(body.length / 1024)} KB Audio, Sprache ${language}`);

  let job;
  try {
    const submit = await falFetch(FAL_SUBMIT_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!submit.ok) {
      console.log(`fal submit -> ${submit.status}`);
      sendJson(res, 502, { error: { message: `fal.ai-Submit fehlgeschlagen (${submit.status})` } });
      log(502);
      return;
    }
    job = await submit.json();
  } catch (e) {
    sendJson(res, 502, { error: { message: 'fal.ai nicht erreichbar' } });
    log(502);
    return;
  }

  if (!job.status_url || !job.response_url) {
    sendJson(res, 502, { error: { message: 'Unerwartete fal.ai-Antwort (keine Queue-URLs)' } });
    log(502);
    return;
  }

  const deadline = Date.now() + FAL_POLL_TIMEOUT_MS;
  try {
    while (Date.now() < deadline) {
      await sleep(FAL_POLL_INTERVAL_MS);
      const statusResp = await falFetch(job.status_url);
      if (!statusResp.ok) continue; // voruebergehender Fehler: weiter pollen
      const status = await statusResp.json();
      if (status.status === 'COMPLETED') {
        const resultResp = await falFetch(job.response_url);
        if (!resultResp.ok) {
          sendJson(res, 502, { error: { message: `fal.ai-Ergebnis nicht abrufbar (${resultResp.status})` } });
          log(502);
          return;
        }
        const buf = Buffer.from(await resultResp.arrayBuffer());
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(buf);
        log(200);
        return;
      }
      if (status.status === 'FAILED') {
        sendJson(res, 502, { error: { message: 'fal.ai-Transkription fehlgeschlagen' } });
        log(502);
        return;
      }
      // IN_QUEUE / IN_PROGRESS: weiter pollen
    }
    sendJson(res, 504, { error: { message: 'fal.ai-Transkription hat zu lange gedauert' } });
    log(504);
  } catch (e) {
    sendJson(res, 502, { error: { message: 'Fehler beim Warten auf fal.ai' } });
    log(502);
  }
}

const server = http.createServer(async (req, res) => {
  const started = Date.now();
  const path = (req.url || '').split('?')[0];
  let logUser = '-';

  const log = (status) =>
    console.log(`${req.method} ${path} [${logUser}] -> ${status} (${Date.now() - started}ms)`);

  // Healthcheck ohne Auth, verraet nichts.
  if (req.method === 'GET' && path === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
    log(200);
    return;
  }

  const isMeeting = path === MEETING_PATH;
  if (req.method !== 'POST' || (!ALLOWED_OPENAI_PATHS.has(path) && !isMeeting)) {
    sendJson(res, 404, { error: { message: 'Not found' } });
    log(404);
    return;
  }

  // App-Passwort pruefen, Nutzer fuers Log identifizieren.
  const user = identifyUser(extractBearer(req));
  if (!user) {
    sendJson(res, 401, { error: { message: 'Ungueltiges App-Passwort' } });
    log(401);
    return;
  }
  logUser = user;

  let body;
  try {
    body = await readBody(req);
  } catch (e) {
    if (e.message === 'PAYLOAD_TOO_LARGE') {
      sendJson(res, 413, { error: { message: 'Audio zu gross (max 60 MB)' } });
      log(413);
    } else {
      sendJson(res, 400, { error: { message: 'Fehler beim Lesen der Anfrage' } });
      log(400);
    }
    return;
  }

  if (isMeeting) {
    await handleMeetingTranscription(req, res, body, log);
    return;
  }

  // Weiterleiten an OpenAI mit dem echten Key.
  const headers = {
    'Authorization': `Bearer ${OPENAI_API_KEY}`,
  };
  if (req.headers['content-type']) headers['Content-Type'] = req.headers['content-type'];
  if (req.headers['accept']) headers['Accept'] = req.headers['accept'];

  try {
    const upstream = await fetch(OPENAI_BASE + path, {
      method: 'POST',
      headers,
      body,
    });

    const buf = Buffer.from(await upstream.arrayBuffer());
    const outHeaders = {};
    const ct = upstream.headers.get('content-type');
    if (ct) outHeaders['Content-Type'] = ct;
    res.writeHead(upstream.status, outHeaders);
    res.end(buf);
    log(upstream.status);
  } catch (e) {
    sendJson(res, 502, { error: { message: 'Upstream-Fehler beim Weiterleiten an OpenAI' } });
    log(502);
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Blitztext-Proxy laeuft auf 127.0.0.1:${PORT}`);
});
