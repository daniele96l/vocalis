# Vocalis license proxy

Cloudflare Worker that accepts a **license code** from Vocalis and proxies STT / cleanup to OpenAI and xAI using **your** API keys. Friends never see those keys.

## One-time setup

```bash
cd workers/vocalis-proxy
npm install
npx wrangler login

# Your provider keys (stay on the Worker — never in the Mac app)
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put XAI_API_KEY

# Comma-separated list from Scripts/mint-licenses.sh output, e.g.
# VOC-AAAA-BBBB-CCCC,VOC-DDDD-EEEE-FFFF,...
npx wrangler secret put LICENSE_CODES

npx wrangler deploy
```

Deployed URL: `https://vocalis-proxy.daniele96ligato.workers.dev`  
(That matches `VocalisConfig.defaultLicenseProxyURL`. Override with `license_proxy_url` in config if you change accounts.)

## Routes

| Method | Path | Upstream |
|--------|------|----------|
| GET | `/` or `/health` | health JSON |
| POST | `/v1/audio/transcriptions` | OpenAI |
| POST | `/v1/chat/completions` | OpenAI |
| POST | `/v1/stt` | xAI Grok STT |

Auth: `Authorization: Bearer <license-code>`.

## Revoke a friend

Remove their code from `LICENSE_CODES` and run `npx wrangler secret put LICENSE_CODES` again (paste the new list), then redeploy if needed. Secret updates apply without a full code redeploy.

## Mint codes locally

From the repo root:

```bash
./Scripts/mint-licenses.sh 10
# → licenses.json (gitignored) + prints comma-separated list for LICENSE_CODES
```
