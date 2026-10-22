// Run locally once. Credentials are written with mode 0600 and never printed.
import {randomBytes,createHmac,createHash} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import webpush from 'web-push';
const auth=randomBytes(32).toString('hex'), nonce=randomBytes(16).toString('hex');
const admin=nonce+createHmac('sha256',auth).update(nonce).digest('hex').slice(0,32);
const vapid=webpush.generateVAPIDKeys();
writeFileSync(new URL('../.dev.vars',import.meta.url),`AUTH_KEY=${auth}\nADMIN_HASH=${createHash('sha256').update(admin).digest('hex')}\nVAPID_PUBLIC_KEY=${vapid.publicKey}\nVAPID_PRIVATE_KEY=${vapid.privateKey}\n`,{mode:0o600,flag:'wx'});
writeFileSync(new URL('../.admin-token',import.meta.url),admin,{mode:0o600,flag:'wx'});
console.log('Created .dev.vars and .admin-token. Keep private. Do not commit.');
