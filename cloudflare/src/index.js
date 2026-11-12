const encoder = new TextEncoder();
const json = (data, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
});
const b64u = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");
const fromB64u = (s) => Uint8Array.from(atob(s.replace(/-/g,"+").replace(/_/g,"/") + "=".repeat((4-s.length%4)%4)), c => c.charCodeAt(0));
const sha = async (s) => b64u(await crypto.subtle.digest("SHA-256", encoder.encode(s)));
async function passwordHash(password, salt = crypto.getRandomValues(new Uint8Array(16))) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({name:"PBKDF2",salt,iterations:100000,hash:"SHA-256"}, key, 256);
  return saltToString(salt) + "." + b64u(bits);
}
function saltToString(salt) { return b64u(salt); }
async function vaultKey(env) {
  const raw = await crypto.subtle.digest("SHA-256", encoder.encode("izvinitevpn-key-vault-v1:" + env.JWT_SECRET));
  return crypto.subtle.importKey("raw", raw, {name:"AES-GCM"}, false, ["encrypt","decrypt"]);
}
async function encryptUserKey(value, env) {
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const encrypted=await crypto.subtle.encrypt({name:"AES-GCM",iv},await vaultKey(env),encoder.encode(value));
  return "enc1:"+b64u(iv)+":"+b64u(encrypted);
}
async function decryptUserKey(stored, env) {
  const parts=String(stored||"").split(":");
  if(parts.length!==3 || parts[0]!=="enc1") return null;
  try {
    const plain=await crypto.subtle.decrypt({name:"AES-GCM",iv:fromB64u(parts[1])},await vaultKey(env),fromB64u(parts[2]));
    return new TextDecoder().decode(plain);
  } catch { return null; }
}
async function passwordVerify(password, stored, env) {
  if(String(stored||"").startsWith("enc1:")) {
    const actual=await decryptUserKey(stored,env);
    return actual!==null && constantTime(actual,password);
  }
  const [saltPart, hashPart] = String(stored).split(".");
  if (!saltPart || !hashPart) return false;
  const actual = await passwordHash(password, fromB64u(saltPart));
  return constantTime(actual.split(".")[1], hashPart);
}
function constantTime(a,b) {
  if (a.length !== b.length) return false;
  let out=0; for(let i=0;i<a.length;i++) out |= a.charCodeAt(i)^b.charCodeAt(i);
  return out===0;
}
async function sign(payload, secret) {
  const head = b64u(encoder.encode(JSON.stringify({alg:"HS256",typ:"JWT"})));
  const body = b64u(encoder.encode(JSON.stringify(payload)));
  const key = await crypto.subtle.importKey("raw",encoder.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const sig = b64u(await crypto.subtle.sign("HMAC",key,encoder.encode(head+"."+body)));
  return head+"."+body+"."+sig;
}
async function verify(token, secret) {
  const parts=String(token||"").split(".");
  if(parts.length!==3) throw new Error("token");
  const key=await crypto.subtle.importKey("raw",encoder.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["verify"]);
  if(!await crypto.subtle.verify("HMAC",key,fromB64u(parts[2]),encoder.encode(parts[0]+"."+parts[1]))) throw new Error("signature");
  const p=JSON.parse(new TextDecoder().decode(fromB64u(parts[1])));
  if(p.iss!=="izvinitevpn" || p.exp*1000<=Date.now()) throw new Error("expired");
  return p;
}
const fingerprint = sha;
const userView = u => ({id:u.id,username:u.username,role:u.role,status:userStatus(u)});
const userStatus = u => u.status==="blocked"?"blocked":u.expires_at && Date.parse(u.expires_at)<=Date.now()?"expired":"active";
async function tokenFor(u, env) {
  const now=Math.floor(Date.now()/1000);
  return sign({sub:String(u.id),role:u.role,mustChangePassword:!!u.must_change_password,iat:now,exp:now+31536000,iss:"izvinitevpn"},env.JWT_SECRET);
}
async function ensureAdmin(env) {
  const row=await env.DB.prepare("SELECT id FROM users WHERE role='admin' LIMIT 1").first();
  if(row) return;
  if(!env.ADMIN_USERNAME || !env.ADMIN_BOOTSTRAP_KEY) throw new Error("Admin bootstrap secrets are missing");
  const hash=await passwordHash(env.ADMIN_BOOTSTRAP_KEY);
  await env.DB.prepare("INSERT INTO users(username,role,key_hash,key_fingerprint,status,must_change_password) VALUES(?,'admin',?,?,'active',1)")
    .bind(env.ADMIN_USERNAME,hash,await fingerprint(env.ADMIN_BOOTSTRAP_KEY)).run();
}
async function currentUser(request, env, requireAdmin=false, allowPasswordChange=false) {
  const raw=request.headers.get("authorization")||"";
  let payload;
  try {
    payload=await verify(raw.replace(/^Bearer\s+/i,""),env.JWT_SECRET);
  } catch {
    throw new Response("Сессия недействительна или истекла",{status:401});
  }
  const u=await env.DB.prepare("SELECT * FROM users WHERE id=?").bind(Number(payload.sub)).first();
  if(!u || !u.key_hash || userStatus(u)!=="active") throw new Response("Доступ отозван, заблокирован или истёк",{status:401});
  if(requireAdmin && u.role!=="admin") throw new Response("Недостаточно прав",{status:403});
  const path=new URL(request.url).pathname;
  if(u.must_change_password && !(allowPasswordChange && path==="/api/auth/change-password")) throw new Response("Сначала смените первоначальный пароль",{status:403});
  return u;
}
async function event(env,type,message) {
  await env.DB.prepare("INSERT INTO events(type,message) VALUES(?,?)").bind(type,message.slice(0,240)).run();
}
async function handle(request,env) {
  await ensureAdmin(env);
  const url=new URL(request.url), path=url.pathname, method=request.method;
  if(method==="GET" && path==="/health") return json({ok:true});
  if(method==="POST" && path==="/api/auth/login") {
    const body=await request.json(), username=String(body.username||"").trim(), key=String(body.key||""), device=String(body.deviceId||"");
    if(!username||!key||device.length<16||device.length>128) return json({error:"Заполните ник, ключ и устройство"},400);
    const u=await env.DB.prepare("SELECT * FROM users WHERE username=? COLLATE NOCASE").bind(username).first();
    if(!u || !(await passwordVerify(key,u.key_hash,env))) { await event(env,"auth_failed","Неудачная попытка входа: "+username.slice(0,48)); return json({error:"Неверный ник или ключ доступа"},401); }
    if(userStatus(u)!=="active") { await event(env,"access_denied","Отказ во входе: "+u.username); return json({error:userStatus(u)==="expired"?"Срок доступа истёк":"Учётная запись заблокирована"},403); }
    if(u.role!=="admin") {
      const known=await env.DB.prepare("SELECT id FROM devices WHERE user_id=? AND device_id=?").bind(u.id,device).first();
      const count=await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE user_id=?").bind(u.id).first();
      if(!known && count.n>=u.max_devices) { await event(env,"device_limit","Превышен лимит устройств: "+u.username); return json({error:"Достигнут лимит устройств"},403); }
      await env.DB.prepare("INSERT INTO devices(user_id,device_id,last_seen) VALUES(?,?,CURRENT_TIMESTAMP) ON CONFLICT(user_id,device_id) DO UPDATE SET last_seen=CURRENT_TIMESTAMP").bind(u.id,device).run();
    }
    await event(env,"login","Новый вход: "+u.username);
    return json({token:await tokenFor(u,env),mustChangePassword:!!u.must_change_password,user:userView(u)});
  }
  if(method==="POST" && path==="/api/auth/change-password") {
    let u; try {u=await currentUser(request,env,false,true);} catch(e) {if(e instanceof Response)return json({error:await e.text()},e.status);throw e;}
    const body=await request.json(), current=String(body.currentKey||""), next=String(body.newKey||"");
    if(!(await passwordVerify(current,u.key_hash,env))) return json({error:"Текущий пароль не подходит"},401);
    if(next.length<12||next.length>128) return json({error:"Пароль должен содержать от 12 до 128 символов"},400);
    const hash=await passwordHash(next);
    await env.DB.prepare("UPDATE users SET key_hash=?,key_fingerprint=?,must_change_password=0 WHERE id=?").bind(hash,await fingerprint(next),u.id).run();
    await event(env,"password_changed","Пароль изменён: "+u.username);
    const updated={...u,must_change_password:0};
    return json({ok:true,token:await tokenFor(updated,env)});
  }
  let u;
  try {u=await currentUser(request,env,path.startsWith("/api/admin/"));} catch(e) {if(e instanceof Response)return json({error:await e.text()},e.status);throw e;}
  if(method==="GET" && path==="/api/auth/me") return json({user:userView(u)});
  if(method==="GET" && path==="/api/admin/stats") {
    const a=await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE role='user' AND key_hash<>'' AND status='active' AND (expires_at IS NULL OR datetime(expires_at)>CURRENT_TIMESTAMP)").first();
    const b=await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE role='user' AND key_hash<>'' AND status='blocked'").first();
    const k=await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE role='user' AND key_hash<>''").first();
    return json({activeUsers:a.n,blockedUsers:b.n,issuedKeys:k.n});
  }
  if(method==="GET" && path==="/api/admin/users") {
    const q=String(url.searchParams.get("q")||"").trim();
    const base="SELECT u.*,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) AS device_count FROM users u WHERE u.role='user'";
    let rows;
    if(!q) rows=(await env.DB.prepare(base+" AND u.key_hash<>'' ORDER BY u.created_at DESC LIMIT 300").all()).results;
    else {
      const byName=(await env.DB.prepare(base+" AND u.key_hash<>'' AND u.username LIKE ? COLLATE NOCASE LIMIT 100").bind("%"+q.slice(0,80)+"%").all()).results;
      const byKey=q.length>=8?(await env.DB.prepare(base+" AND u.key_hash<>'' AND u.key_fingerprint=? LIMIT 20").bind(await fingerprint(q)).all()).results:[];
      rows=[...new Map([...byName,...byKey].map(x=>[x.id,x])).values()];
    }
    const revoked=(await env.DB.prepare(base+" AND u.key_hash='' ORDER BY u.created_at DESC LIMIT 100").all()).results;
    const view=async x=>({id:x.id,username:x.username,status:userStatus(x),expiresAt:x.expires_at,createdAt:x.created_at,maxDevices:x.max_devices,deviceCount:x.device_count,key:await decryptUserKey(x.key_hash,env)});
    return json({users:await Promise.all(rows.map(view)),revokedUsers:await Promise.all(revoked.map(view))});
  }
  if(method==="POST" && path==="/api/admin/users") {
    const body=await request.json(), username=String(body.username||"").trim(), days=Number(body.days), maxDevices=Number(body.maxDevices);
    if(!/^[\p{L}\p{N}_.-]{3,32}$/u.test(username)) return json({error:"Некорректный ник"},400);
    if(![0,7,30,90].includes(days)||![1,2].includes(maxDevices)) return json({error:"Недопустимые параметры ключа"},400);
    const suppliedKey=String(body.key||"").trim();
    if(suppliedKey && (suppliedKey.length<12 || suppliedKey.length>128)) return json({error:"Ключ должен содержать от 12 до 128 символов"},400);
    const newKey=suppliedKey || b64u(crypto.getRandomValues(new Uint8Array(32))), hash=await encryptUserKey(newKey,env), expires=days===0?null:new Date(Date.now()+days*86400000).toISOString();
    try {
      const r=await env.DB.prepare("INSERT INTO users(username,role,key_hash,key_fingerprint,status,expires_at,max_devices) VALUES(?,'user',?,?,'active',?,?)").bind(username,hash,await fingerprint(newKey),expires,maxDevices).run();
      await event(env,"user_created","Создан пользователь: "+username);
      return json({user:{id:Number(r.meta.last_row_id),username},key:newKey},201);
    } catch { return json({error:"Такой ник уже существует"},409); }
  }
  const statusMatch=path.match(/^\/api\/admin\/users\/(\d+)\/status$/);
  if(method==="PATCH" && statusMatch) {
    const status=String((await request.json()).status||"");
    if(!["active","blocked"].includes(status)) return json({error:"Недопустимый статус"},400);
    if(status==="active") { const target=await env.DB.prepare("SELECT key_hash FROM users WHERE id=? AND role='user'").bind(Number(statusMatch[1])).first(); if(!target || !target.key_hash) return json({error:"У этого пользователя ключ отозван. Создай новую учётную запись с новым ключом."},409); }
    const r=await env.DB.prepare("UPDATE users SET status=? WHERE id=? AND role='user'").bind(status,Number(statusMatch[1])).run();
    if(!r.meta.changes) return json({error:"Пользователь не найден"},404);
    const x=await env.DB.prepare("SELECT username FROM users WHERE id=?").bind(Number(statusMatch[1])).first();
    await event(env,"user_status","Статус "+x.username+": "+status); return json({ok:true});
  }
  const editMatch=path.match(/^\/api\/admin\/users\/(\d+)$/);
  if(method==="PATCH" && editMatch) {
    const body=await request.json(), id=Number(editMatch[1]);
    const username=String(body.username||"").trim(), days=Number(body.days), maxDevices=Number(body.maxDevices);
    if(!/^[\p{L}\p{N}_.-]{3,32}$/u.test(username)) return json({error:"Некорректный ник"},400);
    if(![0,7,30,90].includes(days)||![1,2].includes(maxDevices)) return json({error:"Недопустимые параметры"},400);
    const target=await env.DB.prepare("SELECT id FROM users WHERE id=? AND role='user' AND key_hash<>''").bind(id).first();
    if(!target) return json({error:"Пользователь не найден или ключ отозван"},404);
    const expires=days===0?null:new Date(Date.now()+days*86400000).toISOString();
    try { await env.DB.prepare("UPDATE users SET username=?,expires_at=?,max_devices=? WHERE id=? AND role='user'").bind(username,expires,maxDevices,id).run(); }
    catch { return json({error:"Такой ник уже существует"},409); }
    await event(env,"user_updated","Изменены данные пользователя: "+username);
    return json({ok:true});
  }
  if(method==="DELETE" && editMatch) {
    const id=Number(editMatch[1]), target=await env.DB.prepare("SELECT username,key_hash FROM users WHERE id=? AND role='user'").bind(id).first();
    if(!target) return json({error:"Пользователь не найден"},404);
    if(target.key_hash!=="") return json({error:"Сначала отзовите ключ"},409);
    await env.DB.prepare("DELETE FROM devices WHERE user_id=?").bind(id).run();
    await env.DB.prepare("DELETE FROM users WHERE id=? AND role='user' AND key_hash=''").bind(id).run();
    await event(env,"revoked_user_deleted","Удалена запись отозванного ключа: "+target.username);
    return json({ok:true});
  }
  const keyMatch=path.match(/^\/api\/admin\/users\/(\d+)\/key$/);
  if(method==="PATCH" && keyMatch) {
    const body=await request.json(), next=String(body.key||"").trim();
    if(next.length<12 || next.length>128) return json({error:"Ключ должен содержать от 12 до 128 символов"},400);
    const id=Number(keyMatch[1]), target=await env.DB.prepare("SELECT username FROM users WHERE id=? AND role='user'").bind(id).first();
    if(!target) return json({error:"Пользователь не найден"},404);
    await env.DB.prepare("UPDATE users SET key_hash=?,key_fingerprint=?,status='active' WHERE id=? AND role='user'").bind(await encryptUserKey(next,env),await fingerprint(next),id).run();
    await event(env,"key_reset","Ключ обновлён: "+target.username);
    return json({ok:true});
  }
  const revokeMatch=path.match(/^\/api\/admin\/users\/(\d+)\/revoke$/);
  if(method==="POST" && revokeMatch) {
    const r=await env.DB.prepare("UPDATE users SET status='blocked',key_hash='',key_fingerprint='' WHERE id=? AND role='user'").bind(Number(revokeMatch[1])).run();
    await env.DB.prepare("DELETE FROM devices WHERE user_id=?").bind(Number(revokeMatch[1])).run();
    if(!r.meta.changes) return json({error:"Пользователь не найден"},404);
    const x=await env.DB.prepare("SELECT username FROM users WHERE id=?").bind(Number(revokeMatch[1])).first();
    await event(env,"key_revoked","Ключ отозван: "+x.username); return json({ok:true});
  }
  const eventMatch=path.match(/^\/api\/admin\/events\/(\d+)$/);
  if(method==="DELETE" && eventMatch) {
    const r=await env.DB.prepare("DELETE FROM events WHERE id=?").bind(Number(eventMatch[1])).run();
    if(!r.meta.changes) return json({error:"Уведомление не найдено"},404);
    return json({ok:true});
  }
  if(method==="DELETE" && path==="/api/admin/events") {
    await env.DB.prepare("DELETE FROM events").run();
    return json({ok:true});
  }
  if(method==="GET" && path==="/api/admin/events") {
    const rows=(await env.DB.prepare("SELECT id,type,message,created_at,created_at AS createdAt FROM events ORDER BY id DESC LIMIT 100").all()).results;
    return json({events:rows});
  }
  return json({error:"Not found"},404);
}
export default {
  async fetch(request,env) {
    try {
      if(request.method==="OPTIONS") return new Response(null,{status:204,headers:{ "access-control-allow-origin":"*", "access-control-allow-methods":"GET,POST,PATCH,DELETE,OPTIONS", "access-control-allow-headers":"authorization,content-type" }});
      const response=await handle(request,env);
      const headers=new Headers(response.headers);
      headers.set("access-control-allow-origin","*");
      headers.set("access-control-allow-methods","GET,POST,PATCH,DELETE,OPTIONS");
      headers.set("access-control-allow-headers","authorization,content-type");
      return new Response(response.body,{status:response.status,headers});
    } catch(error) {
      console.error("IZVINITEVPN ERROR:", error?.stack || error?.message || String(error));
      return json({error:"Внутренняя ошибка сервера"},500);
    }
  }
};