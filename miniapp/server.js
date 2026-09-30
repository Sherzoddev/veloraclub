const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

function compressed(filePath) {
  const raw = fs.readFileSync(filePath);
  return {
    raw,
    br: zlib.brotliCompressSync(raw, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 6 } }),
    gzip: zlib.gzipSync(raw, { level: 7 }),
  };
}

const pages = new Map([
  ['/', compressed(path.join(__dirname, 'client-webapp.html'))],
  ['/admin', compressed(path.join(__dirname, 'admin.html'))],
]);
const assets = new Map([
  ['/assets/billiards-hero-v1.png', fs.readFileSync(path.join(__dirname, 'assets', 'billiards-hero-v1.png'))],
  ['/assets/member-card-v1.png', fs.readFileSync(path.join(__dirname, 'assets', 'member-card-v1.png'))],
  ['/assets/billiards-hero-v1.webp', fs.readFileSync(path.join(__dirname, 'assets', 'billiards-hero-v1.webp'))],
  ['/assets/member-card-v1.webp', fs.readFileSync(path.join(__dirname, 'assets', 'member-card-v1.webp'))],
  // Member card designs the club picks in the admin Mini App (clubs.card_design).
  ...['pyramid', 'playstation', 'combo', 'neon', 'gold'].map((name) => [
    `/assets/cards/${name}-v1.svg`, fs.readFileSync(path.join(__dirname, 'assets', 'cards', `${name}-v1.svg`)),
  ]),
]);
const ASSET_TYPES = { '.webp': 'image/webp', '.png': 'image/png', '.svg': 'image/svg+xml' };
const port = Number(process.env.PORT || 3000);

http.createServer((request, response) => {
  if (request.url === '/health') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('{"ok":true}');
    return;
  }
  const pathname = new URL(request.url, 'http://localhost').pathname;
  if (assets.has(pathname)) {
    response.writeHead(200, {
      'content-type': ASSET_TYPES[path.extname(pathname)],
      'cache-control': 'public, max-age=31536000, immutable',
      'x-content-type-options': 'nosniff',
    });
    response.end(assets.get(pathname));
    return;
  }
  // Both the client Mini App (/) and the admin Mini App (/admin) are plain
  // static pages served from here rather than from the Supabase edge
  // functions themselves — the Supabase functions gateway rewrites a
  // function's HTML response to text/plain with a locked-down CSP, which
  // makes Telegram render the page as raw source instead of a WebApp.
  const page = pages.get(pathname === '/admin/' ? '/admin' : pathname) ?? (pathname === '/' ? pages.get('/') : null);
  if (!page) {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end('not found');
    return;
  }
  const accepted = request.headers['accept-encoding'] || '';
  const useBr = accepted.includes('br');
  const useGzip = !useBr && accepted.includes('gzip');
  response.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'public, max-age=60, stale-while-revalidate=300',
    'vary': 'accept-encoding',
    ...(useBr ? { 'content-encoding': 'br' } : useGzip ? { 'content-encoding': 'gzip' } : {}),
    'x-content-type-options': 'nosniff',
    'content-security-policy': "default-src 'self' https:; script-src 'self' 'unsafe-inline' https://telegram.org https://unpkg.com https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self' https://aatriitpqpwhdcehjzip.supabase.co; font-src 'self' data: https:; frame-ancestors https://web.telegram.org https://*.telegram.org",
  });
  response.end(useBr ? page.br : useGzip ? page.gzip : page.raw);
}).listen(port, '0.0.0.0', () => {
  console.log(`Velora Mini App listening on ${port}`);
});
