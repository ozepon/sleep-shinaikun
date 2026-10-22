const $=id=>document.getElementById(id), status=s=>$('status').textContent=s;
let phone=localStorage.getItem('phoneToken');
async function api(path,credential,data={}){const r=await fetch('/api/'+path,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+credential},body:JSON.stringify(data)});if(!r.ok)throw Error(r.status===410?'登録コードの期限が切れました。Macで再発行してください。':'接続できませんでした。設定・通信・利用上限を確認してください。');return r.json();}
const standalone=matchMedia('(display-mode: standalone)').matches||navigator.standalone;
if(standalone){$('help').textContent='Macの低残量や、ふたを閉じたことを通知します。';$('setup').hidden=!!phone;$('controls').hidden=!phone;if(phone){api('command/status',phone).then(({command:c})=>{if(c && ['pending','executing'].includes(c.state))check();else if(c?.state==='off')status('前回：Macでスリープ防止のオフを確認しました。');else if(c?.state==='unknown')status('前回の実行結果を確認できません。Mac側の状態をご確認ください。');}).catch(e=>status(e.message));}}
$('register').onclick=async()=>{try{if(!standalone)throw Error('ホーム画面から開いてください。');const pair=$('pair').value.trim();if(!/^[a-f0-9]{64}\.[A-Za-z0-9_-]+$/.test(pair))throw Error('登録コードを確認してください。');const [credential,key]=pair.split('.');if(!('Notification' in window)||!('serviceWorker' in navigator)||!('PushManager' in window))throw Error('通知はiOS 16.4以降のホーム画面アプリで利用できます。iOSとホーム画面への追加を確認してください。');const permission=await Notification.requestPermission();if(permission!=='granted')throw Error('設定で通知を許可してください。');const reg=await navigator.serviceWorker.register('/sw.js');await navigator.serviceWorker.ready;const bytes=Uint8Array.from(atob(key.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));const subscription=await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:bytes});const result=await api('pair/claim',credential,{subscription:subscription.toJSON()});phone=result.phoneToken;localStorage.setItem('phoneToken',phone);$('pair').value='';$('setup').hidden=true;$('controls').hidden=false;status('登録しました。Macからテスト通知を送ってください。');}catch(e){status(e.message);}};
$('off').onclick=async()=>{if(!confirm('接続したMacのスリープ防止をオフにしますか？実行中の処理が止まる場合があります。'))return;$('off').disabled=true;try{await api('command',phone);status('Macの受信と実行を待っています…');await check();}catch(e){status(e.message);}finally{$('off').disabled=false;}};
async function check(){for(let i=0;i<25;i++){const {command:c}=await api('command/status',phone);if(!c)return;if(c.state==='off'){status('Macでスリープ防止がオフになったことを確認しました。');return;}if(c.state==='failed'){status('Macでオフにできませんでした。Macの限定許可・設定を確認してください。');return;}if(c.state==='expired'){status('Macが指示を受信する前に期限が切れました。この指示は実行しません。');return;}if(c.state==='unknown'){status('Macは受信しましたが、実行結果が届いていません。Mac側の状態をご確認ください。');return;}await new Promise(r=>setTimeout(r,5000));}status('完了を確認できません。Mac側の状態をご確認ください。');}

$('scan').onclick=async()=>{
 let stream;
 try {
  stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment',width:{ideal:640}},audio:false});
  const v=$('camera');v.srcObject=stream;v.hidden=false;await v.play();
  const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d',{willReadFrequently:true});const until=Date.now()+60000;
  function stop(){stream.getTracks().forEach(t=>t.stop());v.hidden=true;v.srcObject=null;}
  function frame(){if(Date.now()>until){stop();status('読み取りを終了しました。もう一度お試しいただくか、登録コードを貼り付けてください。');return;}
   if(v.readyState>=2){canvas.width=v.videoWidth;canvas.height=v.videoHeight;ctx.drawImage(v,0,0);const pixels=ctx.getImageData(0,0,canvas.width,canvas.height),code=jsQR(pixels.data,pixels.width,pixels.height);
    if(code && /^[a-f0-9]{64}\.[A-Za-z0-9_-]+$/.test(code.data)){$('pair').value=code.data;stop();status('読み取りました。「通知を許可して登録」を押してください。');return;}}
   requestAnimationFrame(frame);
  }frame();
 }catch{stream?.getTracks().forEach(t=>t.stop());$('camera').hidden=true;status('カメラを利用できません。登録コードを貼り付けてください。');}
};

if(standalone && phone && 'Notification' in window && Notification.permission!=='granted') {
 status('このiPhoneの通知がオフです。iPhoneの設定でスリープしない君の通知を許可してください。');
}
