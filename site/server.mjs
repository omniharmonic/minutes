import http from 'node:http';
import {readFile} from 'node:fs/promises';
const pages = new Map([['/about','about.html'],['/privacy','privacy.html'],['/support','support.html'],['/google730d19efb4075d6c.html','google730d19efb4075d6c.html']]);
const host = '127.0.0.1';
const port = Number(process.env.PORT || 8790);
http.createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname.replace(/\/$/,'');
  if (!['GET','HEAD'].includes(request.method)) { response.writeHead(405,{'Allow':'GET, HEAD'}); response.end(); return; }
  const page = pages.get(path);
  if (!page) { response.writeHead(404); response.end('Not found'); return; }
  try {
    const data = await readFile(new URL(`./public/${page}`, import.meta.url));
    response.writeHead(200, {'Content-Type':'text/html; charset=utf-8','Cache-Control':'public, max-age=300','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"});
    response.end(request.method === 'HEAD' ? undefined : data);
  } catch { response.writeHead(503); response.end('Temporarily unavailable'); }
}).listen(port,host,()=>console.log(`Minutes public pages listening on ${host}:${port}`));
