import {Buffer} from 'node:buffer';
export const digest = async s => [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)))].map(n=>n.toString(16).padStart(2,'0')).join('');
export function validSubscription(s) {
  try {
    const u=new URL(s.endpoint);
    const decode=s=>Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
    return u.protocol==='https:' && !u.username && !u.password && !u.port && !u.hash &&
      (u.hostname==='web.push.apple.com' || u.hostname.endsWith('.push.apple.com')) &&
      /^[A-Za-z0-9_-]+$/.test(s.keys.p256dh) && /^[A-Za-z0-9_-]+$/.test(s.keys.auth) &&
      decode(s.keys.p256dh).length===65 && decode(s.keys.p256dh)[0]===4 && decode(s.keys.auth).length===16;
  } catch { return false; }
}
export async function body(req) {
  if (!req.headers.get('Content-Type')?.startsWith('application/json')) throw new Error('body');
  const reader=req.body?.getReader(); if(!reader) throw new Error('body');
  let size=0, chunks=[];
  for (;;) { const {value,done}=await reader.read(); if(done)break; size+=value.length; if(size>4096){await reader.cancel();throw new Error('body');} chunks.push(value); }
  return JSON.parse(new TextDecoder().decode(Buffer.concat(chunks)));
}
