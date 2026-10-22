import {digest,validSubscription,body} from './security.mjs';
import {requestDetails} from './push.mjs';
const json = (body, status=200) => new Response(JSON.stringify(body), {status, headers:{'Content-Type':'application/json','Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'}});
const token = () => crypto.randomUUID().replaceAll('-','') + crypto.randomUUID().replaceAll('-','');
const now=()=>Math.floor(Date.now()/1000);
const kinds={low:'Macのバッテリーが10%未満です。アプリを開いてスリープ防止をオフにできます。',lid:'Macのふたを閉じました。スリープ防止はオンです。',off:'Macのスリープ防止をオフにしました。',failed:'Macのスリープ防止をオフにできませんでした。Macで設定を確認してください。',test:'接続テストです。'};
async function notify(env, device, id, kind) {
  if (!device.subscription) return 'unpaired';
  const t=now(), day=new Date().toISOString().slice(0,10);
  // Every attempt consumes quota. A repeated ID never sends twice, including failed attempts.
  const r=await env.DB.prepare(`INSERT OR IGNORE INTO deliveries(id,device,day,kind,lease)
    SELECT ?,?,?,?,? WHERE (SELECT COUNT(*) FROM deliveries WHERE day=?)<500
    AND (SELECT COUNT(*) FROM deliveries WHERE day=? AND device=?)<10
    AND (SELECT COUNT(*) FROM deliveries WHERE state='sending' AND lease>?)<2`).bind(id,device.id,day,kind,t+15,day,day,device.id,t).run();
  if(!r.meta.changes)return 'limited_or_duplicate';
  let state='failed';
  try {
    const sub=JSON.parse(device.subscription); if(!validSubscription(sub))throw new Error('endpoint');
    const details=await requestDetails(sub,JSON.stringify({title:'スリープしない君',body:kinds[kind],url:'/'}),env);
    const response=await fetch(details.endpoint,{method:'POST',headers:details.headers,body:details.body,redirect:'manual',signal:AbortSignal.timeout(5000)});
    state=response.ok?'accepted':'failed';
    if(response.status===404||response.status===410)await env.DB.prepare('UPDATE devices SET subscription=NULL WHERE id=?').bind(device.id).run();
  } catch {} // No secrets or endpoints in logs; no automatic retries.
  await env.DB.prepare('UPDATE deliveries SET state=? WHERE id=?').bind(state,id).run();
  return state;
}
async function route(req,env) {
  const path=new URL(req.url).pathname;
  if(!path.startsWith('/api/'))return env.ASSETS.fetch(req);
  if(typeof env.AUTH_KEY!=='string'||env.AUTH_KEY.length<32||!env.ADMIN_HASH||!env.VAPID_PUBLIC_KEY||!env.VAPID_PRIVATE_KEY)return json({error:'not_configured'},503);
  if(env.DISABLED==='1')return json({error:'paused'},503);
  if(req.method!=='POST')return json({error:'method'},405);
  if (!(await env.LIMITER.limit({key:req.headers.get('CF-Connecting-IP')||'local'})).success)return json({error:'rate_limited'},429);
  const origin=req.headers.get('Origin');
  if(origin && origin!==new URL(req.url).origin)return json({error:'origin'},403);
  const raw=req.headers.get('Authorization')?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
  if(!raw)return json({error:'unauthorized'},401);
  // Tokens carry a server HMAC suffix, so random Internet traffic never queries D1.
  const signed=raw.slice(0,32), signature=raw.slice(32);
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(env.AUTH_KEY),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const expected=[...new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(signed)))].map(n=>n.toString(16).padStart(2,'0')).join('').slice(0,32);
  let diff=0; for(let i=0;i<32;i++)diff|=expected.charCodeAt(i)^signature.charCodeAt(i);
  const signedToken=async()=>{const a=token().slice(0,32);const b=[...new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(a)))].map(n=>n.toString(16).padStart(2,'0')).join('');return a+b.slice(0,32);};
  // Admin credential uses the same signed format, generated offline with AUTH_KEY.
  if(diff)return json({error:'unauthorized'},401);
  const hash=await digest(raw);
  if (!(await env.TOKEN_LIMITER.limit({key:hash})).success)return json({error:'rate_limited'},429);
  if(path==='/api/admin/revoke' && hash===env.ADMIN_HASH){
    const b=await body(req);if(typeof b.id!=='string')return json({error:'id'},400);
    await env.DB.prepare('UPDATE devices SET active=0,subscription=NULL,pair_hash=NULL,phone_hash=NULL WHERE id=?').bind(b.id).run();return json({ok:true});
  }
  if(path==='/api/admin/enroll') {
    if(hash!==env.ADMIN_HASH)return json({error:'unauthorized'},401);
    const mac=await signedToken(), id=crypto.randomUUID();
    const r=await env.DB.prepare('INSERT INTO devices(id,mac_hash) SELECT ?,? WHERE (SELECT COUNT(*) FROM devices WHERE active=1)<50').bind(id,await digest(mac)).run();
    return r.meta.changes?json({macToken:mac,id}):json({error:'capacity'},409);
  }
  if(path==='/api/pair/claim') {
    const b=await body(req);if(!validSubscription(b.subscription))return json({error:'subscription'},400);
    const phone=await signedToken();
    const d=await env.DB.prepare('UPDATE devices SET phone_hash=?,subscription=?,pair_hash=NULL,pair_until=NULL WHERE pair_hash=? AND pair_until>? AND active=1 RETURNING id').bind(await digest(phone),JSON.stringify(b.subscription),hash,now()).first();
    return d?json({phoneToken:phone}):json({error:'expired'},410);
  }
  const d=await env.DB.prepare('SELECT * FROM devices WHERE active=1 AND (mac_hash=? OR phone_hash=?)').bind(hash,hash).first();
  if(!d)return json({error:'unauthorized'},401);
  const mac=d.mac_hash===hash;
  if(path==='/api/status')return json({paired:!!d.subscription,remoteAvailable:!!d.subscription});
  if(path==='/api/pair' && mac) {
    const pair=await signedToken();
    await env.DB.prepare('UPDATE devices SET pair_hash=?,pair_until=? WHERE id=?').bind(await digest(pair),now()+300,d.id).run();
    return json({pairToken:pair,expiresIn:300,publicKey:env.VAPID_PUBLIC_KEY});
  }
  if(path==='/api/command' && !mac) {
    await env.DB.prepare("UPDATE commands SET state=CASE WHEN state='pending' THEN 'expired' ELSE 'unknown' END WHERE device=? AND state IN ('pending','executing') AND expires<=?").bind(d.id,now()).run();
    const id=crypto.randomUUID();
    await env.DB.prepare("INSERT OR IGNORE INTO commands(id,device,state,created,expires) SELECT ?,?,'pending',?,? WHERE (SELECT COUNT(*) FROM commands WHERE device=? AND created>?)<10 AND (SELECT COUNT(*) FROM commands WHERE created>?)<500").bind(id,d.id,now(),now()+120,d.id,now()-86400,now()-86400).run();
    const command=await env.DB.prepare("SELECT id,state,expires FROM commands WHERE device=? ORDER BY created DESC,rowid DESC LIMIT 1").bind(d.id).first();
    if(!command || !['pending','executing'].includes(command.state))return json({error:'command_limit'},429);
    return json({command});
  }
  if(path==='/api/command/status' && !mac) {
    const command=await env.DB.prepare('SELECT id,state,expires FROM commands WHERE device=? ORDER BY created DESC,rowid DESC LIMIT 1').bind(d.id).first();
    if(command && command.expires<=now() && ['pending','executing'].includes(command.state))command.state=command.state==='pending'?'expired':'unknown';
    return json({command});
  }
  if(path==='/api/poll' && mac) {
    const c=await env.DB.prepare("UPDATE commands SET state='executing' WHERE id=(SELECT id FROM commands WHERE device=? AND state='pending' AND expires>? LIMIT 1) RETURNING id,expires").bind(d.id,now()).first();
    return json({command:c});
  }
  if(path==='/api/result' && mac) {
    const b=await body(req);if(typeof b.id!=='string'||!['off','failed'].includes(b.state))return json({error:'result'},400);
    const r=await env.DB.prepare("UPDATE commands SET state=?,completed=? WHERE id=? AND device=? AND state IN ('executing','unknown') RETURNING id").bind(b.state,now(),b.id,d.id).first();
    if(r)await notify(env,d,'result-'+b.id,b.state);
    return json({ok:!!r});
  }
  if(path==='/api/notify' && mac) {
    const b=await body(req);if(!['low','lid','test'].includes(b.kind)||typeof b.id!=='string'||!/^[a-zA-Z0-9-]{1,80}$/.test(b.id))return json({error:'notification'},400);
    return json({delivery:await notify(env,d,d.id+'-'+b.id,b.kind)});
  }
  return json({error:'forbidden'},403);
}
export default {async scheduled(event,env,ctx){ctx.waitUntil(env.DB.batch([env.DB.prepare('DELETE FROM deliveries WHERE day<?').bind(new Date(Date.now()-7*86400000).toISOString().slice(0,10)),env.DB.prepare('DELETE FROM commands WHERE created<?').bind(now()-7*86400)]));},async fetch(req,env){try{return await route(req,env);}catch{return json({error:'request_failed'},400);}}};
