import express from 'express';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import Database from 'better-sqlite3';
import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const { PORT=8080, DATABASE_FILE='./data/izvinitevpn.sqlite', JWT_SECRET, ADMIN_USERNAME, ADMIN_BOOTSTRAP_KEY } = process.env;
if (!JWT_SECRET || JWT_SECRET.length < 32) throw new Error('JWT_SECRET must contain at least 32 characters');
if (!ADMIN_USERNAME || !ADMIN_BOOTSTRAP_KEY) throw new Error('Set ADMIN_USERNAME and ADMIN_BOOTSTRAP_KEY as host secrets');
fs.mkdirSync(path.dirname(path.resolve(DATABASE_FILE)), { recursive: true });
const db = new Database(DATABASE_FILE);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');
db.exec(\`
CREATE TABLE IF NOT EXISTS users (
 id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE COLLATE NOCASE,
 role TEXT NOT NULL DEFAULT 'user', key_hash TEXT NOT NULL, key_fingerprint TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'active', expires_at TEXT, max_devices INTEGER NOT NULL DEFAULT 1,
 must_change_password INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS devices (
 id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 device_id TEXT NOT NULL, last_seen TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(user_id,device_id)
);
CREATE TABLE IF NOT EXISTS events (
 id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, message TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);\`);
const fingerprint = value => createHash('sha256').update(value).digest('hex');
const log = db.prepare('INSERT INTO events(type,message) VALUES(?,?)');
if (!db.prepare("SELECT id FROM users WHERE role='admin'").get()) {
 const hash = await bcrypt.hash(ADMIN_BOOTSTRAP_KEY, 12);
 db.prepare("INSERT INTO users(username,role,key_hash,key_fingerprint,status,must_change_password) VALUES(?,'admin',?,?,'active',1)")
  .run(ADMIN_USERNAME, hash, fingerprint(ADMIN_BOOTSTRAP_KEY));
}
const app = express();
app.disable('x-powered-by'); app.use(helmet()); app.use(express.json({limit:'16kb'}));
app.use('/api/auth/login', rateLimit({windowMs:900000,limit:12,standardHeaders:true,legacyHeaders:false}));
const tokenFor = u => jwt.sign({sub:String(u.id),role:u.role,mustChangePassword:!!u.must_change_password},JWT_SECRET,{expiresIn:'365d',issuer:'izvinitevpn'});
function auth(role) {
 return (req,res,next) => {
  try {
   const raw=(req.headers.authorization||'').replace(/^Bearer\s+/i,'');
   const payload=jwt.verify(raw,JWT_SECRET,{issuer:'izvinitevpn'});
   const u=db.prepare('SELECT * FROM users WHERE id=?').get(Number(payload.sub));
   if (!u || u.status!=='active' || (u.expires_at && Date.parse(u.expires_at)<=Date.now())) return res.status(401).json({error:'Доступ отозван, заблокирован или истёк'});
   if (role && u.role!==role) return res.status(403).json({error:'Недостаточно прав'});
   if (u.must_change_password && !req.path.endsWith('/change-password')) return res.status(403).json({error:'Сначала смените первоначальный пароль'});
   req.user=u; next();
  } catch { return res.status(401).json({error:'Требуется повторный вход'}); }
 };
}
function userStatus(u) { return u.status==='blocked'?'blocked':u.expires_at&&Date.parse(u.expires_at)<=Date.now()?'expired':'active'; }
app.get('/health',(_q,res)=>res.json({ok:true}));
app.post('/api/auth/login',async(req,res)=>{
 const username=String(req.body?.username||'').trim(), key=String(req.body?.key||''), device=String(req.body?.deviceId||'');
 if(!username||!key||device.length<16||device.length>128) return res.status(400).json({error:'Заполните ник, ключ и устройство'});
 const u=db.prepare('SELECT * FROM users WHERE username=? COLLATE NOCASE').get(username);
 if(!u || !(await bcrypt.compare(key,u.key_hash))) { log.run('auth_failed','Неудачная попытка входа: '+username.slice(0,48)); return res.status(401).json({error:'Неверный ник или ключ доступа'}); }
 if(userStatus(u)!=='active') { log.run('access_denied','Отказ во входе: '+u.username); return res.status(403).json({error:userStatus(u)==='expired'?'Срок доступа истёк':'Учётная запись заблокирована'}); }
 if(u.role!=='admin') {
  const known=db.prepare('SELECT id FROM devices WHERE user_id=? AND device_id=?').get(u.id,device);
  const count=db.prepare('SELECT COUNT(*) n FROM devices WHERE user_id=?').get(u.id).n;
  if(!known && count>=u.max_devices) { log.run('device_limit','Превышен лимит устройств: '+u.username); return res.status(403).json({error:'Достигнут лимит устройств'}); }
  db.prepare('INSERT INTO devices(user_id,device_id,last_seen) VALUES(?,?,CURRENT_TIMESTAMP) ON CONFLICT(user_id,device_id) DO UPDATE SET last_seen=CURRENT_TIMESTAMP').run(u.id,device);
 }
 log.run('login','Новый вход: '+u.username);
 res.json({token:tokenFor(u),mustChangePassword:!!u.must_change_password,user:{id:u.id,username:u.username,role:u.role,status:userStatus(u)}});
});
app.post('/api/auth/change-password',auth(),async(req,res)=>{
 const current=String(req.body?.currentKey||''), next=String(req.body?.newKey||'');
 if(!(await bcrypt.compare(current,req.user.key_hash))) return res.status(401).json({error:'Текущий пароль не подходит'});
 if(next.length<12||next.length>128) return res.status(400).json({error:'Пароль должен содержать от 12 до 128 символов'});
 const hash=await bcrypt.hash(next,12);
 db.prepare('UPDATE users SET key_hash=?,key_fingerprint=?,must_change_password=0 WHERE id=?').run(hash,fingerprint(next),req.user.id);
 log.run('password_changed','Пароль изменён: '+req.user.username);
 const updated=db.prepare('SELECT * FROM users WHERE id=?').get(req.user.id);
 res.json({ok:true,token:tokenFor(updated)});
});
app.get('/api/auth/me',auth(),(req,res)=>res.json({user:{id:req.user.id,username:req.user.username,role:req.user.role,status:userStatus(req.user)}}));
app.get('/api/admin/stats',auth('admin'),(_q,res)=>res.json({
 activeUsers:db.prepare("SELECT COUNT(*) n FROM users WHERE role='user' AND status='active' AND (expires_at IS NULL OR expires_at>CURRENT_TIMESTAMP)").get().n,
 issuedKeys:db.prepare("SELECT COUNT(*) n FROM users WHERE role='user'").get().n
}));
app.get('/api/admin/users',auth('admin'),(req,res)=>{
 const q=String(req.query.q||'').trim(); let rows;
 if(!q) rows=db.prepare("SELECT u.*,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) device_count FROM users u WHERE role='user' ORDER BY created_at DESC LIMIT 300").all();
 else {
  const byName=db.prepare("SELECT u.*,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) device_count FROM users u WHERE role='user' AND username LIKE ? COLLATE NOCASE LIMIT 100").all('%'+q.slice(0,80)+'%');
  const byKey=q.length>=8?db.prepare("SELECT u.*,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) device_count FROM users u WHERE role='user' AND key_fingerprint=? LIMIT 20").all(fingerprint(q)):[];
  rows=[...new Map([...byName,...byKey].map(u=>[u.id,u])).values()];
 }
 res.json({users:rows.map(u=>({id:u.id,username:u.username,status:userStatus(u),expiresAt:u.expires_at,maxDevices:u.max_devices,deviceCount:u.device_count}))});
});
app.post('/api/admin/users',auth('admin'),async(req,res)=>{
 const username=String(req.body?.username||'').trim(), days=Number(req.body?.days), maxDevices=Number(req.body?.maxDevices);
 if(!/^[\p{L}\p{N}_.-]{3,32}$/u.test(username)) return res.status(400).json({error:'Ник: 3–32 буквы, цифры, точка, дефис или подчёркивание'});
 if(![0,7,30,90].includes(days)||![1,2].includes(maxDevices)) return res.status(400).json({error:'Недопустимые параметры ключа'});
 const key=randomBytes(24).toString('base64url'), hash=await bcrypt.hash(key,12), expires=days===0?null:new Date(Date.now()+days*86400000).toISOString();
 try {
  const r=db.prepare("INSERT INTO users(username,role,key_hash,key_fingerprint,status,expires_at,max_devices) VALUES(?,'user',?,?,'active',?,?)").run(username,hash,fingerprint(key),expires,maxDevices);
  log.run('user_created','Создан пользователь: '+username);
  res.status(201).json({user:{id:Number(r.lastInsertRowid),username},key});
 } catch { res.status(409).json({error:'Такой ник уже существует'}); }
});
app.patch('/api/admin/users/:id/status',auth('admin'),(req,res)=>{
 const s=String(req.body?.status||''); if(!['active','blocked'].includes(s)) return res.status(400).json({error:'Недопустимый статус'});
 const r=db.prepare("UPDATE users SET status=? WHERE id=? AND role='user'").run(s,Number(req.params.id));
 if(!r.changes) return res.status(404).json({error:'Пользователь не найден'});
 const u=db.prepare('SELECT username FROM users WHERE id=?').get(Number(req.params.id)); log.run('user_status','Статус '+u.username+': '+s); res.json({ok:true});
});
app.post('/api/admin/users/:id/revoke',auth('admin'),(req,res)=>{
 const replacement=randomBytes(32).toString('base64url');
 const r=db.prepare("UPDATE users SET status='blocked',key_hash=?,key_fingerprint=? WHERE id=? AND role='user'").run(bcrypt.hashSync(replacement,12),fingerprint(replacement),Number(req.params.id));
 if(!r.changes) return res.status(404).json({error:'Пользователь не найден'});
 const u=db.prepare('SELECT username FROM users WHERE id=?').get(Number(req.params.id)); log.run('key_revoked','Ключ отозван: '+u.username); res.json({ok:true});
});
app.get('/api/admin/events',auth('admin'),(_q,res)=>{
 const rows=db.prepare('SELECT id,type,message,created_at FROM events ORDER BY id DESC LIMIT 100').all();
 res.json({events:rows.map(e=>({...e,createdAt:e.created_at}))});
});
app.listen(PORT,()=>console.log('IzviniteVpn API listening on '+PORT));
