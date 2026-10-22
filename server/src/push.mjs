// RFC 8291 payload encryption uses the maintained web-push/http_ece implementation.
// RFC 8292 VAPID JWT uses Web Crypto ES256; no Node HTTP/TLS transport is imported.
import encryption from 'web-push/src/encryption-helper.js';
import {Buffer} from 'node:buffer';
export async function requestDetails(subscription,payload,env) {
  const endpoint=new URL(subscription.endpoint);
  const publicKey=Buffer.from(env.VAPID_PUBLIC_KEY,'base64url');
  if(publicKey.length!==65||publicKey[0]!==4)throw Error('VAPID key');
  const key=await crypto.subtle.importKey('jwk',{
    kty:'EC',crv:'P-256',x:publicKey.subarray(1,33).toString('base64url'),
    y:publicKey.subarray(33).toString('base64url'),d:env.VAPID_PRIVATE_KEY,ext:true
  },{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
  const encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
  const jwt=encode({typ:'JWT',alg:'ES256'})+'.'+encode({aud:endpoint.origin,exp:Math.floor(Date.now()/1000)+3600,sub:env.VAPID_SUBJECT});
  const signature=Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,new TextEncoder().encode(jwt))).toString('base64url');
  const encrypted=encryption.encrypt(subscription.keys.p256dh,subscription.keys.auth,payload,'aes128gcm');
  return {endpoint:endpoint.href,headers:{TTL:'60','Content-Type':'application/octet-stream','Content-Encoding':'aes128gcm',Authorization:`vapid t=${jwt}.${signature}, k=${env.VAPID_PUBLIC_KEY}`},body:encrypted.cipherText};
}
