const encoder = new TextEncoder();
const json = (data, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
});
const b64u = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");
const fromB64u = (s) => Uint8Array.from(atob(s.replace(/-/g,"+").replace(/_/g,"/") + "=".repeat((4-s.length%4)%4)), c => c.charCodeAt(0));
const sha = async (s) => b64u(await crypto.subtle.digest("SHA-256", encoder.encode(s)));
async function passwordHash(password, salt = crypto.getRandomValues(new Uint8Array(16))) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({name:"PBKDF2",salt,iterations:210000,hash:"SHA-256"}, key, 256);
  return saltToString(salt) + "." + b64u(bits);
}
function saltToString(salt) { return b64u(salt); }
async function passwordVerify(password, stored) {
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
  const payload=await verify(raw.replace(/^Bearer\s+/i,""),env.JWT_SECRET);
  const u=await env.DB.prepare("SELECT * FROM users WHERE id=?").bind(Number(payload.sub)).first();
  if(!u || userStatus(u)!=="active") throw new Response("Доступ отозван, заблокирован или истёк",{status:401});
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
    if(!u || !(await passwordVerify(key,u.key_hash))) { await event(env,"auth_failed","Неудачная попытка входа: "+username.slice(0,48)); return json({error:"Неверный ник или ключ доступа"},401); }
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
    if(!(await passwordVerify(current,u.key_hash))) return json({error:"Текущий пароль не подходит"},401);
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
    const a=await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE role='user' AND status='active' AND (expires_at IS NULL OR expires_at>CURRENT_TIMESTAMP)").first();
    const k=await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE role='user'").first();
    return json({activeUsers:a.n,issuedKeys:k.n});
  }
  if(method==="GET" && path==="/api/admin/users") {
    const q=String(url.searchParams.get("q")||"").trim(); let rows;
    if(!q) rows=(await env.DB.prepare("SELECT u.*,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) AS device_count FROM users u WHERE role='user' ORDER BY created_at DESC LIMIT 300").all()).results;
    else {
      const byName=(await env.DB.prepare("SELECT u.*,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) AS device_count FROM users u WHERE role='user' AND username LIKE ? COLLATE NOCASE LIMIT 100").bind("%"+q.slice(0,80)+"%").all()).results;
      const byKey=q.length>=8?(await env.DB.prepare("SELECT u.*,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) AS device_count FROM users u WHERE role='user' AND key_fingerprint=? LIMIT 20").bind(await fingerprint(q)).all()).results:[];
      rows=[...new Map([...byName,...byKey].map(x=>[x.id,x])).values()];
    }
    return json({users:rows.map(x=>({id:x.id,username:x.username,status:userStatus(x),expiresAt:x.expires_at,maxDevices:x.max_devices,deviceCount:x.device_count}))});
  }
  if(method==="POST" && path==="/api/admin/users") {
    const body=await request.json(), username=String(body.username||"").trim(), days=Number(body.days), maxDevices=Number(body.maxDevices);
    if(!/^[\p{L}\p{N}_.-]{3,32}$/u.test(username)) return json({error:"Ник: 3–32 буквы, цифры, точка, дефис или подчёркивание"},400);
    if(![0,7,30,90].includes(days)||![1,2].includes(maxDevices)) return json({error:"Недопустимые параметры ключа"},400);
    const newKey=b64u(crypto.getRandomValues(new Uint8Array(32))), hash=await passwordHash(newKey), expires=days===0?null:new Date(Date.now()+days*86400000).toISOString();
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
    const r=await env.DB.prepare("UPDATE users SET status=? WHERE id=? AND role='user'").bind(status,Number(statusMatch[1])).run();
    if(!r.meta.changes) return json({error:"Пользователь не найден"},404);
    const x=await env.DB.prepare("SELECT username FROM users WHERE id=?").bind(Number(statusMatch[1])).first();
    await event(env,"user_status","Статус "+x.username+": "+status); return json({ok:true});
  }
  const revokeMatch=path.match(/^\/api\/admin\/users\/(\d+)\/revoke$/);
  if(method==="POST" && revokeMatch) {
    const replacement=b64u(crypto.getRandomValues(new Uint8Array(32)));
    const r=await env.DB.prepare("UPDATE users SET status='blocked',key_hash=?,key_fingerprint=? WHERE id=? AND role='user'").bind(await passwordHash(replacement),await fingerprint(replacement),Number(revokeMatch[1])).run();
    if(!r.meta.changes) return json({error:"Пользователь не найден"},404);
    const x=await env.DB.prepare("SELECT username FROM users WHERE id=?").bind(Number(revokeMatch[1])).first();
    await event(env,"key_revoked","Ключ отозван: "+x.username); return json({ok:true});
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
      if(request.method==="OPTIONS") return new Response(null,{status:204,headers:{ "access-control-allow-origin":"*", "access-control-allow-methods":"GET,POST,PATCH,OPTIONS", "access-control-allow-headers":"authorization,content-type" }});
      const response=await handle(request,env);
      const headers=new Headers(response.headers);
      headers.set("access-control-allow-origin","*");
      headers.set("access-control-allow-methods","GET,POST,PATCH,OPTIONS");
      headers.set("access-control-allow-headers","authorization,content-type");
      return new Response(response.body,{status:response.status,headers});
    } catch(error) {
      console.error("IZVINITEVPN ERROR:", error?.stack || error?.message || String(error));
      return json({error:"Внутренняя ошибка сервера"},500);
    }
  }
};