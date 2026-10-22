import {readFileSync,writeFileSync} from 'node:fs';
const origin=process.argv[2],output=process.argv[3];
if(!origin||!output)throw Error('Usage: node scripts/enroll.mjs https://your.workers.dev /private/path/mac-connection.json');
const u=new URL(origin);if(u.protocol!=='https:'||!u.hostname.endsWith('.workers.dev'))throw Error('Invalid origin');
const admin=readFileSync(new URL('../.admin-token',import.meta.url),'utf8').trim();
const response=await fetch(new URL('/api/admin/enroll',origin),{method:'POST',headers:{Authorization:'Bearer '+admin},redirect:'error'});
if(!response.ok)throw Error('Enrollment failed: '+response.status);
const result=await response.json();writeFileSync(output,JSON.stringify({origin,...result},null,2),{mode:0o600,flag:'wx'});console.log('Saved private connection file. Do not share.');
