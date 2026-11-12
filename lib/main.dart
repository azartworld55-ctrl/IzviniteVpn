import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sing_box/sing_box.dart';

const apiUrl = String.fromEnvironment('API_BASE_URL');
const subUrl = 'https://github.com/FLAT447/v2ray-lists/raw/refs/heads/main/BLACK_LTE.txt';
const orange = Color(0xFFFF7A1A);
const panel = Color(0xFF1B1B1B);
final api = Api();

class ApiException implements Exception {final int status;final String message;ApiException(this.status,this.message);@override String toString()=>message;}

class Api {
  String? token;
  Uri uri(String p) => Uri.parse(apiUrl.replaceAll(RegExp(r'/$'), '') + '/api' + p);
  Map<String,String> get headers => {'Content-Type':'application/json', if(token != null) 'Authorization':'Bearer $token'};
  Future<Map<String,dynamic>> call(String method,String path,[Map<String,dynamic>? body]) async {
    if(apiUrl.isEmpty) throw Exception('Сервер авторизации ещё не настроен');
    final u=uri(path);
    final r=method=='GET' ? await http.get(u,headers:headers) : method=='PATCH'
      ? await http.patch(u,headers:headers,body:jsonEncode(body??{}))
      : method=='DELETE' ? await http.delete(u,headers:headers)
      : await http.post(u,headers:headers,body:jsonEncode(body??{}));
    final d=r.body.isEmpty?<String,dynamic>{}:jsonDecode(r.body) as Map<String,dynamic>;
    if(r.statusCode<200 || r.statusCode>=300) throw ApiException(r.statusCode,d['error']??'Ошибка сервера');
    return d;
  }
}

Future<String> deviceId() async {
  final p=await SharedPreferences.getInstance();
  var id=p.getString('device_id');
  if(id==null){ final r=Random.secure(); id=List.generate(32,(_)=>r.nextInt(16).toRadixString(16)).join(); await p.setString('device_id',id); }
  return id;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SingBox.instance.initialize(const SingBoxOptions(android:SingBoxAndroidOptions(
    notificationTitle:'IzviniteVpn',showTrafficInNotification:true,stopActionTitle:'Отключить')));
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override Widget build(BuildContext c)=>MaterialApp(title:'IzviniteVpn',debugShowCheckedModeBanner:false,
    theme:ThemeData(brightness:Brightness.dark,scaffoldBackgroundColor:const Color(0xFF101010),
      colorScheme:ColorScheme.fromSeed(seedColor:orange,brightness:Brightness.dark,surface:panel),useMaterial3:true),
    home:const SessionGate());
}

class SessionGate extends StatefulWidget {
  const SessionGate({super.key});
  @override State<SessionGate> createState() => _SessionGateState();
}
class _SessionGateState extends State<SessionGate> {
  @override void initState() { super.initState(); restore(); }
  Future<void> restore() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('session_token');
    if (saved != null) {
      api.token = saved;
      try {
        final me = await api.call('GET', '/auth/me');
        if (!mounted) return;
        openUser(me['user']);
        return;
      } catch (_) {
        await p.remove('session_token');
        api.token = null;
      }
    }
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }
  void openUser(dynamic user) {
    Navigator.pushReplacement(context, MaterialPageRoute(
      builder: (_) => user['role'] == 'admin' ? const AdminPage() : const HomePage()));
  }
  @override Widget build(BuildContext c) => const Scaffold(
    body: Center(child: CircularProgressIndicator(color: orange)));
}

class LoginPage extends StatefulWidget { const LoginPage({super.key}); @override State<LoginPage> createState()=>_LoginState(); }
class _LoginState extends State<LoginPage> {
  final n=TextEditingController(),k=TextEditingController(); bool busy=false; String? error;
  Future<void> login() async {
    setState(()=>busy=true); error=null;
    try {
      final d=await api.call('POST','/auth/login',{'username':n.text.trim(),'key':k.text,'deviceId':await deviceId()});
      api.token=d['token'];
      final p=await SharedPreferences.getInstance();
      await p.setString('session_token',api.token!);
      if(!mounted)return;
      final u=d['user'];
      Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>d['mustChangePassword']==true
        ? ChangePasswordPage(initialKey:k.text) : u['role']=='admin'?const AdminPage():const HomePage()));
    } catch(e){setState(()=>error=e.toString().replaceFirst('Exception: ',''));}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override void dispose(){n.dispose();k.dispose();super.dispose();}
  @override Widget build(BuildContext c)=>Scaffold(body:SafeArea(child:Center(child:SingleChildScrollView(
    padding:const EdgeInsets.all(24),
    child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:420),child:Column(
      crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const Icon(Icons.shield_rounded,color:orange,size:76),
        const SizedBox(height:12),
        const Text('IzviniteVpn',textAlign:TextAlign.center,style:TextStyle(fontSize:30,fontWeight:FontWeight.w800)),
        const SizedBox(height:34),
        TextField(controller:n,decoration:const InputDecoration(labelText:'Ник пользователя',prefixIcon:Icon(Icons.person_outline))),
        const SizedBox(height:14),
        TextField(controller:k,obscureText:true,onSubmitted:(_)=>login(),decoration:const InputDecoration(labelText:'Ключ доступа',prefixIcon:Icon(Icons.key))),
        if(error!=null) Padding(padding:const EdgeInsets.only(top:12),child:Text(error!,style:const TextStyle(color:Colors.redAccent))),
        const SizedBox(height:22),
        FilledButton(onPressed:busy||apiUrl.isEmpty?null:login,
          style:FilledButton.styleFrom(backgroundColor:orange,foregroundColor:Colors.black),
          child:Text(busy?'Проверка…':'Войти')),
        if(apiUrl.isEmpty) const Padding(padding:EdgeInsets.only(top:12),
          child:Text('Сервер авторизации ещё не настроен.',textAlign:TextAlign.center)),
      ]))))));
}

class ChangePasswordPage extends StatefulWidget {
  final String initialKey; const ChangePasswordPage({super.key,required this.initialKey});
  @override State<ChangePasswordPage> createState()=>_ChangePasswordState();
}
class _ChangePasswordState extends State<ChangePasswordPage>{
  final a=TextEditingController(),b=TextEditingController();String? error;bool busy=false;
  Future<void> save() async{
    if(a.text.length<12||a.text!=b.text){setState(()=>error='Пароли должны совпадать и содержать не менее 12 символов.');return;}
    setState(()=>busy=true);
    try{
      final d=await api.call('POST','/auth/change-password',{'currentKey':widget.initialKey,'newKey':a.text});
      api.token=d['token'];final p=await SharedPreferences.getInstance();await p.setString('session_token',api.token!);
      final me=await api.call('GET','/auth/me');if(!mounted)return;
      Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>me['user']['role']=='admin'?const AdminPage():const HomePage()));
    }catch(e){setState(()=>error=e.toString());}finally{if(mounted)setState(()=>busy=false);}
  }
  @override void dispose(){a.dispose();b.dispose();super.dispose();}
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Сменить пароль')),body:ListView(padding:const EdgeInsets.all(22),children:[
    const Text('Установи новый пароль для администратора.'),const SizedBox(height:16),
    TextField(controller:a,obscureText:true,decoration:const InputDecoration(labelText:'Новый пароль')),
    const SizedBox(height:12),TextField(controller:b,obscureText:true,decoration:const InputDecoration(labelText:'Повтори пароль')),
    if(error!=null)Text(error!,style:const TextStyle(color:Colors.redAccent)),
    const SizedBox(height:20),FilledButton(onPressed:busy?null:save,child:Text(busy?'Сохранение…':'Сохранить')),
  ]));
}

abstract class SessionState<T extends StatefulWidget> extends State<T> with WidgetsBindingObserver {
  Timer? _sessionTimer;
  bool _checkingSession = false;
  void startSessionWatch() {
    WidgetsBinding.instance.addObserver(this);
    _sessionTimer = Timer.periodic(const Duration(minutes: 15), (_) => ensureSession());
  }
  Future<bool> ensureSession() async {
    if (_checkingSession || !mounted) return true;
    if (api.token == null) return false;
    _checkingSession = true;
    try {
      await api.call('GET', '/auth/me');
      return true;
    } catch (e) {
      if(e is ApiException && (e.status==401 || e.status==403)){
        final p=await SharedPreferences.getInstance();await p.remove('session_token');api.token=null;
        if(mounted)Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder:(_)=>const LoginPage()),(_)=>false);
      }
      return false;
    } finally {
      _checkingSession = false;
    }
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ensureSession();
  }
  @override void dispose() {
    _sessionTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class HomePage extends StatefulWidget{const HomePage({super.key});@override State<HomePage> createState()=>_HomeState();}
class _HomeState extends SessionState<HomePage>{
  List<SingBoxServerConfig> servers=[];final Map<String,int> ping={};
  StreamSubscription? pinger,statsSub,statusSub,stateSub;
  String down='0 B/s',up='0 B/s';bool busy=false,loadingServers=false,checkingPings=false,sortBestFirst=false,isAdmin=false;
  String? error,selected,activeCountry;
  SingBoxConnectionStatus connectionStatus=SingBox.instance.status;
  bool get connected=>connectionStatus==SingBoxConnectionStatus.connected;
  @override void initState(){super.initState();startSessionWatch();
    statusSub=SingBox.instance.watchConnectionStatus().listen((v){if(mounted)setState(()=>connectionStatus=v);});
    stateSub=SingBox.instance.watchConnectionState().listen((v){if(mounted&&v.error!=null)setState(()=>error='Ошибка VPN: ${v.error}');});
    statsSub=SingBox.instance.watchConnectionStats().listen((s){if(mounted)setState((){down=rate(s.downloadSpeed);up=rate(s.uploadSpeed);});});
    loadRole();loadServers();
  }
  Future<void> loadRole()async{try{final d=await api.call('GET','/auth/me');if(mounted)setState(()=>isAdmin=d['user']['role']=='admin');}catch(_){if(mounted)setState(()=>error='Сервер авторизации недоступен.');}}
  String rate(int n)=>n<1024?'$n B/s':n<1048576?'${(n/1024).toStringAsFixed(1)} KB/s':'${(n/1048576).toStringAsFixed(1)} MB/s';
  Future<void> loadServers()async{
    if(mounted)setState(()=>loadingServers=true);
    try{final r=await http.get(Uri.parse(subUrl)).timeout(const Duration(seconds:25));if(r.statusCode!=200)throw Exception('HTTP ${r.statusCode}');
      await SingBox.instance.importServerConfigs(r.body,subscriptionId:'black-lte');final a=await SingBox.instance.getServerConfigs();
      if(a.isEmpty)throw Exception('Нет поддерживаемых серверов');if(mounted)setState((){servers=a;selected=selected??a.first.id;error=null;});
    }catch(e){if(mounted)setState(()=>error='Ошибка подписки: $e');}finally{if(mounted)setState(()=>loadingServers=false);}
  }
  void testPings(){if(servers.isEmpty||checkingPings)return;pinger?.cancel();ping.clear();setState(()=>checkingPings=true);
    pinger=SingBox.instance.pingServers(servers,concurrency:8).listen((r){if(mounted)setState(()=>ping[r.serverId??'']=r.success?r.ping:-1);},
      onError:(e){if(mounted)setState((){error='Ошибка проверки МС: $e';checkingPings=false;});},
      onDone:(){if(mounted)setState(()=>checkingPings=false);});
  }
  List<SingBoxServerConfig> get sorted{final a=[...servers];if(sortBestFirst)a.sort((x,y)=>(ping[x.id]??999999).compareTo(ping[y.id]??999999));return a;}
  Future<void> restoreActiveServer()async{
    if(!connected)return;
    try{final a=await SingBox.instance.getActiveServerConfig();if(a!=null&&mounted){setState(()=>selected=a.id);activeCountry=countryFor(a.name);}}
    catch(_){}
  }
  String countryFor(String name){
    final n=name.toLowerCase();const m={'germany':'🇩🇪 Германия','deutsch':'🇩🇪 Германия','герман':'🇩🇪 Германия','германия':'🇩🇪 Германия','netherlands':'🇳🇱 Нидерланды','holland':'🇳🇱 Нидерланды','нидерланды':'🇳🇱 Нидерланды','finland':'🇫🇮 Финляндия','france':'🇫🇷 Франция','usa':'🇺🇸 США','united states':'🇺🇸 США','uk':'🇬🇧 Великобритания','sweden':'🇸🇪 Швеция','poland':'🇵🇱 Польша','turkey':'🇹🇷 Турция','japan':'🇯🇵 Япония','singapore':'🇸🇬 Сингапур','canada':'🇨🇦 Канада','switzerland':'🇨🇭 Швейцария','austria':'🇦🇹 Австрия','latvia':'🇱🇻 Латвия','estonia':'🇪🇪 Эстония','czech':'🇨🇿 Чехия','italy':'🇮🇹 Италия','spain':'🇪🇸 Испания','russia':'🇷🇺 Россия'};
    for(final e in m.entries){if(n.contains(e.key))return e.value;}return '🌐 $name';
  }
  void announceCountry(String name){final v=countryFor(name);setState(()=>activeCountry=v);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Активная страна: $v'),duration:const Duration(seconds:3)));}
  Future<void> connect({bool auto=false})async{
    if(busy||servers.isEmpty)return;if(!await ensureSession()){setState(()=>error='Сервер авторизации недоступен.');return;}
    setState((){busy=true;error=null;});
    try{if(!connected)await SingBox.instance.connectToServers(servers);
      if(auto){await SingBox.instance.selectOutbound(SingBoxConfigBuilder.proxyTag,SingBoxConfigBuilder.autoTag);final a=await SingBox.instance.getActiveServerConfig();if(a!=null){setState(()=>selected=a.id);announceCountry(a.name);}}
      else{final s=servers.firstWhere((x)=>x.id==selected,orElse:()=>servers.first);await SingBox.instance.selectOutbound(SingBoxConfigBuilder.proxyTag,s.name);setState(()=>selected=s.id);announceCountry(s.name);}
    }catch(e){if(mounted)setState(()=>error='Ошибка VPN: $e');}finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> disconnectVpn()async{if(busy)return;setState(()=>busy=true);try{await SingBox.instance.disconnect();await SingBox.instance.waitForStatus(SingBoxConnectionStatus.disconnected);}catch(e){if(mounted)setState(()=>error='Ошибка VPN: $e');}finally{if(mounted)setState(()=>busy=false);}}
  Future<void> choose(dynamic s)async{try{setState(()=>selected=s.id as String);if(connected)await SingBox.instance.selectOutbound(SingBoxConfigBuilder.proxyTag,s.name as String);if(mounted){announceCountry(s.name as String);Navigator.pop(context);}}catch(e){if(mounted)setState(()=>error='Ошибка выбора сервера: $e');}}
  @override void dispose(){pinger?.cancel();statsSub?.cancel();statusSub?.cancel();stateSub?.cancel();super.dispose();}
  @override Widget build(BuildContext c){
    final label=connectionStatus==SingBoxConnectionStatus.connecting?'Подключение…':connectionStatus==SingBoxConnectionStatus.connected?'Подключено':connectionStatus==SingBoxConnectionStatus.disconnecting?'Отключение…':(error?.startsWith('Ошибка VPN:')??false)?'Ошибка':'Отключено';
    final tint=label=='Подключено'?Colors.greenAccent:label=='Ошибка'?Colors.redAccent:orange;
    return Scaffold(appBar:AppBar(title:const Text('IzviniteVpn'),actions:[if(isAdmin)IconButton(tooltip:'Панель администратора',onPressed:()=>Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>const AdminPage())),icon:const Icon(Icons.admin_panel_settings,color:orange))]),
      body:ListView(padding:const EdgeInsets.all(18),children:[
        if(activeCountry!=null&&connected)Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.symmetric(horizontal:14,vertical:12),decoration:BoxDecoration(color:orange.withOpacity(.12),borderRadius:BorderRadius.circular(14),border:Border.all(color:orange.withOpacity(.45))),child:Row(children:[const Icon(Icons.public,color:orange),const SizedBox(width:10),Expanded(child:Text('Активная страна: $activeCountry',style:const TextStyle(fontWeight:FontWeight.w600)))])),
        AnimatedContainer(duration:const Duration(milliseconds:350),padding:const EdgeInsets.all(22),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(24),border:Border.all(color:tint.withOpacity(.55))),
          child:Column(children:[
            AnimatedSwitcher(duration:const Duration(milliseconds:280),child:Icon(label=='Подключено'?Icons.verified_rounded:label=='Ошибка'?Icons.error_outline:Icons.shield_rounded,key:ValueKey(label),size:66,color:tint)),
            const SizedBox(height:12),AnimatedSwitcher(duration:const Duration(milliseconds:250),child:Text(label,key:ValueKey(label),style:TextStyle(fontSize:25,fontWeight:FontWeight.bold,color:tint))),
            if(label=='Подключение…')const Padding(padding:EdgeInsets.only(top:12),child:SizedBox(width:22,height:22,child:CircularProgressIndicator(strokeWidth:2,color:orange))),
            if(activeCountry!=null&&connected)Padding(padding:const EdgeInsets.only(top:10),child:Text('Активная страна: $activeCountry')),
            const SizedBox(height:20),
            SizedBox(width:double.infinity,child:FilledButton(onPressed:busy?null:(){HapticFeedback.lightImpact();if(connected){disconnectVpn();}else{connect();}},style:FilledButton.styleFrom(backgroundColor:orange,foregroundColor:Colors.black,padding:const EdgeInsets.symmetric(vertical:15)),child:Text(connected?'Отключиться':label=='Подключение…'?'Подключение…':'Подключиться'))),
            const SizedBox(height:12),Row(children:[Expanded(child:OutlinedButton(onPressed:servers.isEmpty?null:openServers,child:const Text('Выбрать сервер'))),const SizedBox(width:8),Expanded(child:OutlinedButton(onPressed:busy||servers.isEmpty?null:()=>connect(auto:true),child:const Text('Автовыбор')))]),
          ])),
        card('Статистика',[line('Загрузка',down),line('Отдача',up)]),
        if(loadingServers)const Padding(padding:EdgeInsets.all(12),child:Center(child:CircularProgressIndicator(color:orange))),
        if(error!=null)Padding(padding:const EdgeInsets.only(top:12),child:Text(error!,style:const TextStyle(color:Colors.redAccent))),
        const SizedBox(height:20),const Text('Автор: Юсупов И.',textAlign:TextAlign.center,style:TextStyle(color:Colors.white38)),
      ]));
  }
  Widget card(String t,List<Widget> children)=>Container(margin:const EdgeInsets.only(top:14),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(t,style:const TextStyle(fontWeight:FontWeight.bold)),...children]));
  Widget line(String a,String b)=>Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(children:[Expanded(child:Text(a)),Text(b)]));
  void openServers()=>showModalBottomSheet(context:context,isScrollControlled:true,backgroundColor:panel,builder:(c)=>StatefulBuilder(builder:(c,refresh)=>SafeArea(child:SizedBox(height:MediaQuery.of(c).size.height*.84,child:Column(children:[
    const Padding(padding:EdgeInsets.all(18),child:Text('Выбор сервера',style:TextStyle(fontWeight:FontWeight.bold,fontSize:19))),
    Wrap(spacing:6,alignment:WrapAlignment.center,children:[
      OutlinedButton.icon(onPressed:checkingPings?null:(){testPings();refresh((){});},icon:const Icon(Icons.speed),label:Text(checkingPings?'Проверка…':'Проверить МС')),
      OutlinedButton.icon(onPressed:loadingServers?null:(){loadServers();refresh((){});},icon:const Icon(Icons.refresh),label:const Text('Обновить подписку')),
      OutlinedButton.icon(onPressed:(){setState(()=>sortBestFirst=!sortBestFirst);refresh((){});},icon:const Icon(Icons.sort),label:Text(sortBestFirst?'Исходный порядок':'Лучший сверху')),
    ]),
    Expanded(child:GridView.builder(padding:const EdgeInsets.all(12),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,crossAxisSpacing:10,mainAxisSpacing:10,childAspectRatio:1.25),itemCount:sorted.length,itemBuilder:(c,i){
      final v=sorted[i],p=ping[v.id],active=v.id==selected;
      return InkWell(borderRadius:BorderRadius.circular(16),onTap:(){HapticFeedback.selectionClick();choose(v);},child:AnimatedContainer(duration:const Duration(milliseconds:220),padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:active?orange.withOpacity(.12):const Color(0xFF252525),borderRadius:BorderRadius.circular(16),border:Border.all(color:active?orange:Colors.white10,width:active?2:1)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(countryFor(v.name),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold)),
        const SizedBox(height:7),Text(v.name,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:12,color:Colors.white70)),
        const Spacer(),Row(children:[Expanded(child:Text(p==null?'—':p<0?'Timeout':'$p ms',style:const TextStyle(color:orange))),if(active)const Icon(Icons.check_circle,color:orange,size:18)]),
      ]))));
    })),
  ])))));
}
class AdminPage extends StatefulWidget{const AdminPage({super.key});@override State<AdminPage> createState()=>_AdminState();}
class _AdminState extends SessionState<AdminPage>{
  final search=TextEditingController();Map<String,dynamic> stats={};List<dynamic> users=[],events=[];bool busy=false;String? error;
  @override void initState(){super.initState();startSessionWatch();load();}
  @override void dispose(){search.dispose();super.dispose();}
  Future<void> load()async{setState(()=>busy=true);try{final a=await Future.wait([api.call('GET','/admin/stats'),api.call('GET','/admin/users'+(search.text.isEmpty?'':'?q=${Uri.encodeQueryComponent(search.text)}')),api.call('GET','/admin/events')]);if(mounted)setState(() { stats=a[0]; users=a[1]['users']; events=a[2]['events']; });}catch(e){error=e.toString();}finally{if(mounted)setState(()=>busy=false);}}
  Future<void> createUser()async{
    final name=TextEditingController(),keyInput=TextEditingController();int days=30,devices=1;
    final v=await showDialog<Map<String,dynamic>>(context:context,builder:(c)=>StatefulBuilder(builder:(c,refresh)=>AlertDialog(title:const Text('Новый пользователь'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'Ник')),
      const SizedBox(height:10),
      TextField(controller:keyInput,decoration:const InputDecoration(labelText:'Ключ вручную (необязательно)',helperText:'Оставь пустым для автогенерации')),
      DropdownButtonFormField<int>(value:days,decoration:const InputDecoration(labelText:'Срок доступа'),items:const [DropdownMenuItem(value:1,child:Text('1 день')),DropdownMenuItem(value:2,child:Text('2 дня')),DropdownMenuItem(value:7,child:Text('7 дней')),DropdownMenuItem(value:30,child:Text('30 дней')),DropdownMenuItem(value:90,child:Text('90 дней')),DropdownMenuItem(value:0,child:Text('Без ограничения'))],onChanged:(x)=>refresh(()=>days=x??30)),
      DropdownButtonFormField<int>(value:devices,decoration:const InputDecoration(labelText:'Устройства'),items:const [DropdownMenuItem(value:1,child:Text('Одно')),DropdownMenuItem(value:2,child:Text('Два'))],onChanged:(x)=>refresh(()=>devices=x??1)),
    ]),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Отмена')),FilledButton(onPressed:()=>Navigator.pop(c,{'username':name.text.trim(),'key':keyInput.text.trim(),'days':days,'maxDevices':devices}),child:const Text('Создать'))])));
    if(v==null||(v['username'] as String).isEmpty)return;
    try{final r=await api.call('POST','/admin/users',v);if(!mounted)return;await showDialog<void>(context:context,builder:(c)=>AlertDialog(title:const Text('Ключ создан'),content:SelectableText('Ник: ${r['user']['username']}\nКлюч: ${r['key']}\nСохрани ключ сейчас.'),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Закрыть'))]));await load();}catch(e){setState(()=>error=e.toString());}
  }
  Future<void> setKey(dynamic u)async{
    final controller=TextEditingController();int days=30;
    final value=await showDialog<Map<String,dynamic>>(context:context,builder:(c)=>StatefulBuilder(builder:(c,refresh)=>AlertDialog(
      title:Text('Новый ключ: ${u['username']}'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:controller,autofocus:true,decoration:const InputDecoration(labelText:'Ключ (12–128 символов)')),
        DropdownButtonFormField<int>(value:days,decoration:const InputDecoration(labelText:'Срок доступа'),items:const [
          DropdownMenuItem(value:1,child:Text('1 день')),DropdownMenuItem(value:2,child:Text('2 дня')),
          DropdownMenuItem(value:7,child:Text('7 дней')),DropdownMenuItem(value:30,child:Text('30 дней')),
          DropdownMenuItem(value:90,child:Text('90 дней')),DropdownMenuItem(value:0,child:Text('Без ограничения'))],
          onChanged:(x)=>refresh(()=>days=x??30)),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Отмена')),FilledButton(onPressed:()=>Navigator.pop(c,{'key':controller.text.trim(),'days':days}),child:const Text('Сохранить'))])));
    if(value==null){controller.dispose();return;}
    try{await api.call('PATCH','/admin/users/${u['id']}/key',value);await load();}
    catch(e){if(mounted)setState(()=>error=e.toString());}
    finally{controller.dispose();}
  }
  Future<void> toggle(dynamic u)async{try{await api.call('PATCH','/admin/users/${u['id']}/status',{'status':u['status']=='blocked'?'active':'blocked'});await load();}catch(e){setState(()=>error=e.toString());}}
  Future<void> revoke(dynamic u)async{
    final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:const Text('Отозвать ключ?'),
      content:Text('Ключ пользователя ${u['username']} перестанет работать.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Отмена')),
        FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Отозвать'))]));
    if(ok!=true)return;
    try{await api.call('POST','/admin/users/${u['id']}/revoke');await load();}
    catch(e){if(mounted)setState(()=>error=e.toString());}
  }
  Future<bool> confirmAction(String title,String message,String action)async=>await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(title),content:Text(message),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Отмена')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:Text(action))]))??false;
  Future<void> deleteEvent(dynamic e)async{
    if(!await confirmAction('Удалить уведомление?','Событие будет удалено из журнала.','Удалить'))return;
    try{await api.call('DELETE','/admin/events/${e['id']}');await load();}catch(err){if(mounted)setState(()=>error=err.toString());}
  }
  Future<void> clearEvents()async{
    if(events.isEmpty||!await confirmAction('Очистить все уведомления?','История событий будет удалена без возможности восстановления.','Очистить'))return;
    try{await api.call('DELETE','/admin/events');await load();}catch(err){if(mounted)setState(()=>error=err.toString());}
  }
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Администрирование'),actions:[IconButton(tooltip:'Открыть VPN',onPressed:()=>Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>const HomePage())),icon:const Icon(Icons.vpn_key,color:orange)),IconButton(onPressed:load,icon:const Icon(Icons.refresh))]),
    floatingActionButton:FloatingActionButton.extended(onPressed:createUser,backgroundColor:orange,foregroundColor:Colors.black,icon:const Icon(Icons.person_add),label:const Text('Создать ключ')),
    body:RefreshIndicator(onRefresh:load,color:orange,child:ListView(padding:const EdgeInsets.all(16),children:[
      Row(children:[Expanded(child:stat('Активные',stats['activeUsers']??'—')),const SizedBox(width:10),Expanded(child:stat('Выданные ключи',stats['issuedKeys']??'—'))]),
      const SizedBox(height:16),TextField(controller:search,onSubmitted:(_)=>load(),decoration:InputDecoration(labelText:'Поиск по нику или ключу',suffixIcon:IconButton(onPressed:load,icon:const Icon(Icons.search)))),
      const SizedBox(height:12),const Text('Пользователи',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      ...users.map((u)=>Card(color:panel,child:ListTile(title:Text(u['username']),subtitle:Text('${u['status']=='blocked'?'Заблокирован':'Активен'} · Создан: ${u['createdAt']??'—'}\\nСрок: ${u['expiresAt']??'Без ограничения'} · ${u['deviceCount']}/${u['maxDevices']} устройств\\nКлюч: ${u['key']??'недоступен (старый формат)'}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[
        if(u['key']!=null) IconButton(tooltip:'Скопировать ключ',onPressed:()=>Clipboard.setData(ClipboardData(text:u['key'])),icon:const Icon(Icons.copy,color:orange)) else IconButton(tooltip:'Задать новый ключ',onPressed:()=>setKey(u),icon:const Icon(Icons.edit,color:orange)),
        IconButton(onPressed:()=>toggle(u),icon:Icon(u['status']=='blocked'?Icons.lock_open:Icons.block,color:orange)),
        IconButton(onPressed:()=>revoke(u),icon:const Icon(Icons.key_off,color:Colors.redAccent)),
      ])))),
      const SizedBox(height:16),Row(children:[const Expanded(child:Text('Уведомления',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18))),TextButton.icon(onPressed:events.isEmpty?null:clearEvents,icon:const Icon(Icons.delete_sweep),label:const Text('Очистить всё'))]),
      ...events.map((e)=>ListTile(dense:true,leading:const Icon(Icons.notifications_none,color:orange),title:Text(e['message']),subtitle:Text(e['createdAt']),trailing:IconButton(tooltip:'Удалить уведомление',onPressed:()=>deleteEvent(e),icon:const Icon(Icons.delete_outline,color:Colors.redAccent)))),
      if(busy)const Center(child:CircularProgressIndicator(color:orange)),if(error!=null)Text(error!,style:const TextStyle(color:Colors.redAccent)),const SizedBox(height:80),
    ])));
  Widget stat(String t,dynamic v)=>Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('$v',style:const TextStyle(color:orange,fontSize:25,fontWeight:FontWeight.bold)),Text(t)]));
}
