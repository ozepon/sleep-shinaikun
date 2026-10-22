// Real workerd + D1 integration. No external push requests or system settings changed.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {readFileSync} from 'node:fs';
import {createHash,createHmac} from 'node:crypto';
import assert from 'node:assert/strict';
import webpush from 'web-push';
import ece from 'http_ece';
import {createECDH,randomBytes} from 'node:crypto';
const vapid=webpush.generateVAPIDKeys(),receiver=createECDH('prime256v1');receiver.generateKeys();const receiverAuth=randomBytes(16).toString('base64url');let deliveries=0;
const subscription={endpoint:'https://web.push.apple.com/local-test-only',keys:{p256dh:receiver.getPublicKey().toString('base64url'),auth:receiverAuth}};
const auth='local-test-only'.repeat(3);const n='a'.repeat(32);const admin=n+createHmac('sha256',auth).update(n).digest('hex').slice(0,32);
const mf=new Miniflare(convertV4MiniflareOptions({modules:true,script:readFileSync(process.argv[2]||'/tmp/sleep-shinaikun-worker-check/worker.js','utf8'),compatibilityDate:'2026-10-01',compatibilityFlags:['nodejs_compat'],outboundService:async request=>{assert.equal(new URL(request.url).hostname,'web.push.apple.com');const encrypted=Buffer.from(await request.arrayBuffer());const data=JSON.parse(ece.decrypt(encrypted,{version:'aes128gcm',privateKey:receiver,authSecret:receiverAuth}).toString());assert.equal(data.title,'スリープしない君');assert.equal(data.body,'Macのスリープ防止をオフにしました。');deliveries++;return new Response('',{status:201});},d1Databases:['DB'],bindings:{AUTH_KEY:auth,ADMIN_HASH:createHash('sha256').update(admin).digest('hex'),VAPID_PUBLIC_KEY:vapid.publicKey,VAPID_PRIVATE_KEY:vapid.privateKey,VAPID_SUBJECT:'https://example.org'},ratelimits:{LIMITER:{namespace_id:'1001',simple:{limit:100,period:60}},TOKEN_LIMITER:{namespace_id:'1002',simple:{limit:100,period:60}}}}));
try{
 const db=await mf.getD1Database('DB');
 // D1 exec() accepts one SQL statement per line.
 await db.exec(readFileSync(new URL('../migrations/0001.sql',import.meta.url),'utf8').replace(/\n/g,' ').replaceAll(';',';\n'));
 const call=async(path,token,data={})=>{const r=await mf.dispatchFetch('https://notify.example/api/'+path,{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(data)});return {status:r.status,body:await r.json()};};
 assert.equal((await call('poll','0'.repeat(64))).status,401);
 const a=await call('admin/enroll',admin);assert.equal(a.status,200);
 const pair=await call('pair',a.body.macToken);assert.equal(pair.status,200);assert.equal(pair.body.expiresIn,300);
 const claimed=await call('pair/claim',pair.body.pairToken,{subscription});assert.equal(claimed.status,200);const phone=claimed.body.phoneToken;
 const clicked=await Promise.all(Array.from({length:10},()=>call('command',phone)));
 assert.equal(new Set(clicked.map(c=>c.body.command.id)).size,1);
 const c=clicked[0].body.command;assert.equal(c.state,'pending');
 assert.equal((await call('result',phone,{id:c.id,state:'off'})).status,403);
 assert.equal((await call('poll',a.body.macToken)).body.command.id,c.id);
 assert.equal((await call('poll',a.body.macToken)).body.command,null);
 assert.equal((await call('command/status',phone)).body.command.state,'executing');
 const finished=await call('result',a.body.macToken,{id:c.id,state:'off'});assert.equal(finished.body.ok,true);
 assert.equal((await call('command/status',phone)).body.command.state,'off');assert.equal(deliveries,1);
 assert.equal((await call('result',a.body.macToken,{id:c.id,state:'off'})).body.ok,false);assert.equal(deliveries,1);
 const expired=await call('command',phone);assert.equal(expired.status,200);
 await db.prepare('UPDATE commands SET expires=0 WHERE id=?').bind(expired.body.command.id).run();
 assert.equal((await call('poll',a.body.macToken)).body.command,null);assert.equal((await call('command/status',phone)).body.command.state,'expired');
 const rows=await db.prepare('SELECT COUNT(*) n FROM devices').first();assert.equal(rows.n,1);
 const calls=await Promise.all(Array.from({length:60},()=>call('admin/enroll',admin)));
 assert.equal(calls.filter(r=>r.status===200).length,49);
 assert.equal(calls.filter(r=>r.status===409).length,11);
 console.log('Real workerd/D1 integration passed: forged auth, pairing, 10 concurrent clicks coalesced, role separation, single claim, verified completion, encrypted Push decrypted by receiver, no duplicate completion push, expired command rejected, 60 concurrent enrollments capped at 50.');
}finally{await mf.dispose();}
