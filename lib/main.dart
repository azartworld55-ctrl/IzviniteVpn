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

class Api {
  String? token;
  Uri uri(String p) => Uri.parse(apiUrl.replaceAll(RegExp(r'/$'), '') + '/api' + p);
  Map<String,String> get headers => {'Content-Type':'application/json', if(token != null) 'Authorization':'Bearer $token'};
  Future<Map<String,dynamic>> call(String method,String path,[Map<String,dynamic>? body]) async {
    if(apiUrl.isEmpty) throw Exception('Сервер авторизации ещё не настроен');
    final u=uri(path);
    late http.Response r;
    try {
      if (method == 'GET') {
        r = await http.get(u, headers: headers).timeout(const Duration(seconds: 15));
      } else if (method == 'PATCH') {
        r = await http.patch(u, headers: headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 15));
      } else if (method == 'DELETE') {
        r = await http.delete(u, headers: headers).timeout(const Duration(seconds: 15));
      } else {
        r = await http.post(u, headers: headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 15));
      }
    } on TimeoutException {
      throw Exception('Сервер авторизации недоступен: превышено время ожидания.');
    } on http.ClientException {
      throw Exception('Сервер авторизации недоступен. Проверь подключение к интернету.');
    }
    final d=r.body.isEmpty?<String,dynamic>{}:jsonDecode(r.body) as Map<String,dynamic>;
    if(r.statusCode<200 || r.statusCode>=300) throw Exception(d['error']??'Ошибка сервера');
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
    } catch (_) {
      final p = await SharedPreferences.getInstance();
      await p.remove('session_token');
      api.token = null;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomeState();
}

class _HomeState extends SessionState<HomePage> {
  List<SingBoxServerConfig> servers = [];
  final Map<String, int> ping = {};
  StreamSubscription<dynamic>? pinger, statsSub, statusSub, stateSub, groupsSub;
  String down = '0 B/s', up = '0 B/s';
  String? error, vpnError, selected, activeServer;
  bool loadingSubscription = false, checkingPing = false, connecting = false;
  bool sortedByPing = false, isAdmin = false;
  SingBoxConnectionStatus vpnStatus = SingBox.instance.status;

  bool get connected => vpnStatus == SingBoxConnectionStatus.connected;
  bool get busy => connecting || loadingSubscription;

  @override void initState() {
    super.initState();
    startSessionWatch();
    statusSub = SingBox.instance.watchConnectionStatus().listen((status) {
      if (!mounted) return;
      setState(() {
        vpnStatus = status;
        if (status == SingBoxConnectionStatus.connected) vpnError = null;
        if (status == SingBoxConnectionStatus.disconnected && !connecting) activeServer = null;
      });
    });
    stateSub = SingBox.instance.watchConnectionState().listen((state) {
      if (state.error != null && mounted) setState(() => vpnError = state.error.toString());
    });
    groupsSub = SingBox.instance.watchGroups().listen((groups) {
      for (final group in groups) {
        if (group.tag == SingBoxConfigBuilder.proxyTag) {
          final value = group.selected?.toString();
          if (value != null && value.isNotEmpty && mounted) {
            setState(() {
              activeServer = value;
              final found = servers.where((server) => server.name == value).toList();
              if (found.isNotEmpty) selected = found.first.id;
            });
          }
        }
      }
    });
    statsSub = SingBox.instance.watchConnectionStats().listen((stats) {
      if (mounted) setState(() {
        down = rate(stats.downloadSpeed);
        up = rate(stats.uploadSpeed);
      });
    });
    loadRole();
    loadServers();
  }

  Future<void> loadRole() async {
    try {
      final me = await api.call('GET', '/auth/me');
      if (mounted) setState(() => isAdmin = me['user']?['role'] == 'admin');
    } catch (_) {}
  }

  String rate(int value) {
    if (value < 1024) return value.toString() + ' B/s';
    if (value < 1048576) return (value / 1024).toStringAsFixed(1) + ' KB/s';
    return (value / 1048576).toStringAsFixed(1) + ' MB/s';
  }

  String flagFor(String name) {
    final match = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true).firstMatch(name);
    if (match != null) return match.group(0)!;
    const flags = {
      'GERMANY':'🇩🇪','DEUTSCHLAND':'🇩🇪','NETHERLANDS':'🇳🇱','HOLLAND':'🇳🇱',
      'FRANCE':'🇫🇷','UNITED KINGDOM':'🇬🇧','BRITAIN':'🇬🇧','ENGLAND':'🇬🇧',
      'UNITED STATES':'🇺🇸','USA':'🇺🇸','FINLAND':'🇫🇮','SWEDEN':'🇸🇪',
      'NORWAY':'🇳🇴','SWITZERLAND':'🇨🇭','POLAND':'🇵🇱','AUSTRIA':'🇦🇹',
      'BELGIUM':'🇧🇪','SPAIN':'🇪🇸','ITALY':'🇮🇹','CANADA':'🇨🇦','JAPAN':'🇯🇵',
      'SINGAPORE':'🇸🇬','TURKEY':'🇹🇷','TURKIYE':'🇹🇷','LATVIA':'🇱🇻',
      'ESTONIA':'🇪🇪','LITHUANIA':'🇱🇹','ROMANIA':'🇷🇴','BULGARIA':'🇧🇬',
      'CZECH':'🇨🇿','HONG KONG':'🇭🇰','KOREA':'🇰🇷','AUSTRALIA':'🇦🇺',
      'RUSSIA':'🇷🇺','UKRAINE':'🇺🇦',
    };
    final upper = name.toUpperCase();
    for (final entry in flags.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    return '🌐';
  }

  String countryFor(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\u{1F1E6}-\u{1F1FF}]', unicode: true), '')
        .replaceAll(RegExp(r'[_|()[\]{}]+'), ' ').trim();
    const names = [
      'Germany','Deutschland','Netherlands','Holland','France','United Kingdom','Britain',
      'England','United States','USA','Finland','Sweden','Norway','Switzerland','Poland',
      'Austria','Belgium','Spain','Italy','Canada','Japan','Singapore','Turkey','Türkiye',
      'Latvia','Estonia','Lithuania','Romania','Bulgaria','Czechia','Hong Kong',
      'South Korea','Australia','Russia','Ukraine'
    ];
    for (final value in names) {
      if (cleaned.toLowerCase().contains(value.toLowerCase())) return value;
    }
    return cleaned.isEmpty ? 'Сервер' : cleaned;
  }

  Future<void> loadServers() async {
    if (mounted) setState(() { loadingSubscription = true; error = null; });
    try {
      final response = await http.get(Uri.parse(subUrl)).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw Exception('HTTP ' + response.statusCode.toString());
      await SingBox.instance.importServerConfigs(response.body, subscriptionId: 'black-lte');
      final loaded = await SingBox.instance.getServerConfigs();
      if (loaded.isEmpty) throw Exception('Подписка не содержит поддерживаемых серверов');
      if (mounted) setState(() {
        servers = loaded;
        if (selected == null || !servers.any((server) => server.id == selected)) selected = servers.first.id;
        sortedByPing = false;
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось загрузить подписку: ' + e.toString());
    } finally {
      if (mounted) setState(() => loadingSubscription = false);
    }
  }

  Future<void> testPings() async {
    if (servers.isEmpty || checkingPing) return;
    await pinger?.cancel();
    if (mounted) setState(() { checkingPing = true; ping.clear(); });
    pinger = SingBox.instance.pingServers(servers, concurrency: 8).listen(
      (result) {
        if (mounted) setState(() => ping[result.serverId ?? ''] = result.success ? result.ping : -1);
      },
      onError: (e) { if (mounted) setState(() => error = 'Ошибка проверки МС: ' + e.toString()); },
      onDone: () { if (mounted) setState(() { checkingPing = false; sortedByPing = false; }); },
    );
  }

  void sortByPing() => setState(() => sortedByPing = true);

  List<SingBoxServerConfig> get visibleServers {
    final list = [...servers];
    if (sortedByPing) {
      list.sort((a, b) {
        final pa = ping[a.id] ?? 999999, pb = ping[b.id] ?? 999999;
        if (pa < 0 && pb >= 0) return 1;
        if (pb < 0 && pa >= 0) return -1;
        return pa.compareTo(pb);
      });
    }
    return list;
  }

  Future<void> toggleConnection({bool auto = false}) async {
    if (connecting) return;
    if (connected || vpnStatus == SingBoxConnectionStatus.connecting) {
      await disconnectVpn();
      return;
    }
    if (servers.isEmpty) {
      setState(() => error = 'Сначала загрузите подписку.');
      return;
    }
    if (!await ensureSession()) return;
    HapticFeedback.mediumImpact();
    setState(() { connecting = true; vpnError = null; });
    try {
      await SingBox.instance.connectToServers(servers);
      if (auto) {
        await SingBox.instance.selectOutbound(SingBoxConfigBuilder.proxyTag, SingBoxConfigBuilder.autoTag);
      } else {
        final server = servers.firstWhere((item) => item.id == selected, orElse: () => servers.first);
        await SingBox.instance.selectOutbound(SingBoxConfigBuilder.proxyTag, server.name);
      }
      await SingBox.instance.waitForStatus(SingBoxConnectionStatus.connected);
    } catch (e) {
      if (mounted) setState(() => vpnError = e.toString());
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> disconnectVpn() async {
    if (connecting) return;
    HapticFeedback.selectionClick();
    setState(() { connecting = true; vpnError = null; });
    try {
      await SingBox.instance.disconnect();
      if (mounted) setState(() => activeServer = null);
    } catch (e) {
      if (mounted) setState(() => vpnError = e.toString());
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> chooseServer(SingBoxServerConfig server) async {
    HapticFeedback.selectionClick();
    setState(() => selected = server.id);
    try {
      if (connected) {
        await SingBox.instance.selectOutbound(SingBoxConfigBuilder.proxyTag, server.name);
        if (mounted) setState(() { activeServer = server.name; vpnError = null; });
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => vpnError = e.toString());
    }
  }

  @override void dispose() {
    pinger?.cancel();
    statsSub?.cancel();
    statusSub?.cancel();
    stateSub?.cancel();
    groupsSub?.cancel();
    super.dispose();
  }

  String get statusLabel {
    if (vpnError != null && vpnStatus != SingBoxConnectionStatus.connected) return 'Ошибка';
    switch (vpnStatus) {
      case SingBoxConnectionStatus.connecting: return 'Подключение…';
      case SingBoxConnectionStatus.connected: return 'Подключено';
      case SingBoxConnectionStatus.disconnecting: return 'Отключение…';
      case SingBoxConnectionStatus.disconnected: return 'Отключено';
    }
  }

  @override Widget build(BuildContext context) {
    final isConnecting = vpnStatus == SingBoxConnectionStatus.connecting || connecting;
    final isError = statusLabel == 'Ошибка';
    final accent = isError ? Colors.redAccent : connected ? Colors.greenAccent : orange;
    final currentName = activeServer == null || activeServer == SingBoxConfigBuilder.autoTag ? null : activeServer;
    final currentServer = currentName == null ? <SingBoxServerConfig>[] : servers.where((s) => s.name == currentName).toList();
    final displayName = currentServer.isNotEmpty ? currentServer.first.name : currentName;
    final country = displayName == null ? null : countryFor(displayName);
    final flag = displayName == null ? '🌐' : flagFor(displayName);

    return Scaffold(
      appBar: AppBar(
        title: const Text('IzviniteVpn', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (isAdmin) IconButton(
            tooltip: 'Панель администратора',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPage())),
            icon: const Icon(Icons.admin_panel_settings_outlined, color: orange),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 10, 18, 24), children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: connected && country != null
              ? Container(
                  key: ValueKey('country-' + displayName!),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                  decoration: BoxDecoration(color: orange.withOpacity(.10), borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: orange.withOpacity(.35))),
                  child: Row(children: [
                    Text(flag, style: const TextStyle(fontSize: 25)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('ТЕКУЩЕЕ ПОДКЛЮЧЕНИЕ', style: TextStyle(fontSize: 10, color: Colors.white54, letterSpacing: 1)),
                      Text(country, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    ])),
                    const Icon(Icons.verified_rounded, color: Colors.greenAccent),
                  ]),
                )
              : const SizedBox(key: ValueKey('no-country'), height: 4),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 26, 18, 22),
          decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(28),
            border: Border.all(color: accent.withOpacity(.28))),
          child: Column(children: [
            Text('IzviniteVpn', style: TextStyle(color: Colors.white.withOpacity(.55), fontSize: 13, letterSpacing: 2)),
            const SizedBox(height: 8),
            Text(statusLabel, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 20),
            SizedBox(width: 188, height: 188, child: Stack(alignment: Alignment.center, children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 350), width: 160, height: 160,
                decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withOpacity(.09),
                  boxShadow: [
                    if (connected || isConnecting) BoxShadow(color: accent.withOpacity(.34), blurRadius: 34, spreadRadius: 8),
                  ],
                  border: Border.all(color: accent.withOpacity(.7), width: 2)),
              ),
              if (isConnecting) const SizedBox(width: 184, height: 184,
                child: CircularProgressIndicator(color: orange, strokeWidth: 3, strokeCap: StrokeCap.round)),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: busy ? null : () => connected ? disconnectVpn() : toggleConnection(),
                  child: SizedBox(width: 142, height: 142, child: Center(child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Icon(
                      isError ? Icons.error_outline_rounded : connected ? Icons.check_rounded : Icons.power_settings_new_rounded,
                      key: ValueKey(statusLabel), size: 68, color: accent),
                  ))),
                ),
              ),
            ])),
            const SizedBox(height: 12),
            Text(connected ? 'Нажми, чтобы отключиться' : 'Нажми, чтобы подключиться',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: servers.isEmpty ? null : openServers, child: const Text('Выбрать сервер'))),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton(onPressed: servers.isEmpty || busy ? null : () => toggleConnection(auto: true),
                child: const Text('Автовыбор'))),
            ]),
          ]),
        ),
        if (connected && displayName != null) _infoCard('Активный сервер', [
          Row(children: [
            Text(flag, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 10),
            Expanded(child: Text(displayName, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 8),
          Text(country ?? '', style: const TextStyle(color: Colors.white54)),
        ]),
        _infoCard('Трафик', [_metric('Загрузка', down), _metric('Отдача', up)]),
        if (loadingSubscription) const Padding(padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator(color: orange))),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
        if (vpnError != null) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(vpnError!, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 20),
        const Text('Автор: Юсупов И.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white30, fontSize: 11)),
      ]),
    );
  }

  Widget _infoCard(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(top: 14), padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(18)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
      const SizedBox(height: 10), ...children,
    ]),
  );

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [Expanded(child: Text(label)), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))]),
  );

  void openServers() {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: panel,
      builder: (sheetContext) => SafeArea(child: SizedBox(
        height: MediaQuery.of(sheetContext).size.height * .88,
        child: StatefulBuilder(builder: (context, refreshSheet) => Column(children: [
          const Padding(padding: EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Text('Выбор сервера', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Wrap(
            alignment: WrapAlignment.center, spacing: 6, children: [
              TextButton.icon(onPressed: checkingPing ? null : () { testPings(); refreshSheet(() {}); },
                icon: const Icon(Icons.speed, size: 18), label: const Text('Проверить МС')),
              TextButton.icon(onPressed: loadingSubscription ? null : () async { await loadServers(); refreshSheet(() {}); },
                icon: const Icon(Icons.refresh, size: 18), label: const Text('Обновить подписку')),
              TextButton.icon(onPressed: () { sortByPing(); refreshSheet(() {}); },
                icon: const Icon(Icons.sort, size: 18), label: const Text('Сортировка')),
            ],
          )),
          if (checkingPing || loadingSubscription) const Padding(padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(color: orange)),
          Expanded(child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 18),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.2),
            itemCount: visibleServers.length,
            itemBuilder: (context, index) {
              final server = visibleServers[index];
              final latency = ping[server.id];
              final active = connected && activeServer == server.name;
              final chosen = selected == server.id;
              return InkWell(
                borderRadius: BorderRadius.circular(18), onTap: () => chooseServer(server),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180), padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF222222), borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: active || chosen ? orange : Colors.white12, width: active || chosen ? 2 : 1)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Row(children: [Text(flagFor(server.name), style: const TextStyle(fontSize: 23)), const Spacer(),
                      if (active) const Icon(Icons.check_circle, color: orange, size: 18)]),
                    Text(countryFor(server.name), maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(latency == null ? 'МС: —' : latency < 0 ? 'Недоступен' : latency.toString() + ' мс',
                      style: TextStyle(fontSize: 12, color: latency != null && latency >= 0 ? Colors.greenAccent : Colors.white54)),
                  ]),
                ),
              );
            },
          )),
        ])),
      )),
    );
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});
  @override State<AdminPage> createState() => _AdminState();
}

class _AdminState extends SessionState<AdminPage> {
  final search = TextEditingController();
  Timer? searchTimer;
  Map<String, dynamic> stats = {};
  List<dynamic> users = [], revokedUsers = [], events = [];
  bool busy = false;
  String? error;

  @override void initState() { super.initState(); startSessionWatch(); load(); }
  @override void dispose() { searchTimer?.cancel(); search.dispose(); super.dispose(); }

  Future<void> load() async {
    if (mounted) setState(() => busy = true);
    try {
      final results = await Future.wait([
        api.call('GET', '/admin/stats'),
        api.call('GET', '/admin/users' + (search.text.trim().isEmpty ? '' : '?q=' + Uri.encodeQueryComponent(search.text.trim()))),
        api.call('GET', '/admin/events'),
      ]);
      if (mounted) setState(() {
        stats = results[0];
        users = results[1]['users'] ?? [];
        revokedUsers = results[1]['revokedUsers'] ?? [];
        events = results[2]['events'] ?? [];
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void searchChanged(String value) {
    searchTimer?.cancel();
    searchTimer = Timer(const Duration(milliseconds: 280), load);
  }

  Future<void> createUser() async {
    final name = TextEditingController(), keyInput = TextEditingController();
    int days = 30, devices = 1;
    final value = await showDialog<Map<String, dynamic>>(context: context,
      builder: (c) => StatefulBuilder(builder: (c, refresh) => AlertDialog(
        title: const Text('Новый пользователь'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Ник')),
          const SizedBox(height: 10),
          TextField(controller: keyInput, decoration: const InputDecoration(labelText: 'Ключ вручную (необязательно)')),
          DropdownButtonFormField<int>(
            value: days, decoration: const InputDecoration(labelText: 'Срок доступа'),
            items: const [
              DropdownMenuItem(value: 7, child: Text('7 дней')),
              DropdownMenuItem(value: 30, child: Text('30 дней')),
              DropdownMenuItem(value: 90, child: Text('90 дней')),
              DropdownMenuItem(value: 0, child: Text('Без ограничения')),
            ],
            onChanged: (v) => refresh(() => days = v ?? 30),
          ),
          DropdownButtonFormField<int>(
            value: devices, decoration: const InputDecoration(labelText: 'Устройства'),
            items: const [DropdownMenuItem(value: 1, child: Text('1 устройство')), DropdownMenuItem(value: 2, child: Text('2 устройства'))],
            onChanged: (v) => refresh(() => devices = v ?? 1),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, {
            'username': name.text.trim(), 'key': keyInput.text.trim(), 'days': days, 'maxDevices': devices,
          }), child: const Text('Создать')),
        ],
      )));
    if (value == null || (value['username'] as String).isEmpty) {
      name.dispose(); keyInput.dispose(); return;
    }
    try {
      final result = await api.call('POST', '/admin/users', value);
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (c) => AlertDialog(
        title: const Text('Ключ создан'),
        content: SelectableText('Ник: ' + result['user']['username'] + '\nКлюч: ' + result['key'] + '\n\nСохрани ключ сейчас.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Закрыть'))],
      ));
      await load();
    } catch (e) { if (mounted) setState(() => error = e.toString()); }
    finally { name.dispose(); keyInput.dispose(); }
  }

  Future<bool> confirm(String title, String message, String action) async {
    return await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text(title), content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ],
    )) ?? false;
  }

  Future<void> editUser(dynamic user) async {
    final name = TextEditingController(text: user['username'] ?? '');
    int days = 30, devices = (user['maxDevices'] ?? 1) as int;
    final expiry = user['expiresAt']?.toString();
    if (expiry == null) {
      days = 0;
    } else {
      final remaining = DateTime.tryParse(expiry)?.difference(DateTime.now()).inDays ?? 30;
      days = remaining > 70 ? 90 : remaining > 20 ? 30 : 7;
    }
    final value = await showDialog<Map<String, dynamic>>(context: context,
      builder: (c) => StatefulBuilder(builder: (c, refresh) => AlertDialog(
        title: Text('Изменить ' + (user['username'] ?? '')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Ник')),
          DropdownButtonFormField<int>(
            value: days, decoration: const InputDecoration(labelText: 'Срок с сегодняшнего дня'),
            items: const [
              DropdownMenuItem(value: 7, child: Text('7 дней')),
              DropdownMenuItem(value: 30, child: Text('30 дней')),
              DropdownMenuItem(value: 90, child: Text('90 дней')),
              DropdownMenuItem(value: 0, child: Text('Без ограничения')),
            ],
            onChanged: (v) => refresh(() => days = v ?? 30),
          ),
          DropdownButtonFormField<int>(
            value: devices, decoration: const InputDecoration(labelText: 'Лимит устройств'),
            items: const [DropdownMenuItem(value: 1, child: Text('1')), DropdownMenuItem(value: 2, child: Text('2'))],
            onChanged: (v) => refresh(() => devices = v ?? 1),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, {
            'username': name.text.trim(), 'days': days, 'maxDevices': devices,
          }), child: const Text('Сохранить')),
        ],
      )));
    if (value == null) { name.dispose(); return; }
    try { await api.call('PATCH', '/admin/users/' + user['id'].toString(), value); await load(); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
    finally { name.dispose(); }
  }

  Future<void> setKey(dynamic user) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: Text('Новый ключ: ' + user['username']),
      content: TextField(controller: controller, autofocus: true,
        decoration: const InputDecoration(labelText: '12–128 символов')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Сохранить')),
      ],
    ));
    if (value == null) { controller.dispose(); return; }
    try { await api.call('PATCH', '/admin/users/' + user['id'].toString() + '/key', {'key': value}); await load(); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
    finally { controller.dispose(); }
  }

  Future<void> toggleUser(dynamic user) async {
    final blocked = user['status'] == 'blocked';
    if (!blocked && !await confirm('Заблокировать?', 'Доступ пользователя ' + user['username'] + ' будет временно закрыт.', 'Заблокировать')) return;
    try {
      await api.call('PATCH', '/admin/users/' + user['id'].toString() + '/status',
        {'status': blocked ? 'active' : 'blocked'});
      await load();
    } catch (e) { if (mounted) setState(() => error = e.toString()); }
  }

  Future<void> revokeUser(dynamic user) async {
    if (!await confirm('Отозвать ключ?', 'Ключ пользователя ' + user['username'] + ' перестанет работать. Запись останется в разделе отозванных.', 'Отозвать')) return;
    try { await api.call('POST', '/admin/users/' + user['id'].toString() + '/revoke'); await load(); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
  }

  Future<void> deleteRevoked(dynamic user) async {
    if (!await confirm('Удалить запись навсегда?', 'Запись пользователя ' + user['username'] + ' будет удалена. Событие отзыва останется в уведомлениях.', 'Удалить')) return;
    try { await api.call('DELETE', '/admin/users/' + user['id'].toString()); await load(); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
  }

  Future<void> deleteEvent(dynamic event) async {
    try { await api.call('DELETE', '/admin/events/' + event['id'].toString()); await load(); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
  }

  Future<void> clearEvents() async {
    if (events.isEmpty || !await confirm('Очистить уведомления?', 'Удалятся все события, включая историю отзыва ключей.', 'Очистить всё')) return;
    try { await api.call('DELETE', '/admin/events'); await load(); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Администрирование'), actions: [
      IconButton(tooltip: 'Открыть VPN', onPressed: () => Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const HomePage())), icon: const Icon(Icons.vpn_key, color: orange)),
      IconButton(tooltip: 'Обновить', onPressed: load, icon: const Icon(Icons.refresh)),
    ]),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: createUser, backgroundColor: orange, foregroundColor: Colors.black,
      icon: const Icon(Icons.person_add), label: const Text('Создать ключ')),
    body: RefreshIndicator(color: orange, onRefresh: load, child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
        Row(children: [
          Expanded(child: _stat('Активные', stats['activeUsers'] ?? '—')),
          const SizedBox(width: 8),
          Expanded(child: _stat('Заблокированы', stats['blockedUsers'] ?? '—')),
          const SizedBox(width: 8),
          Expanded(child: _stat('Ключи', stats['issuedKeys'] ?? '—')),
        ]),
        const SizedBox(height: 16),
        TextField(controller: search, onChanged: searchChanged, decoration: InputDecoration(
          labelText: 'Поиск по нику или ключу', prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(onPressed: () { search.clear(); load(); }, icon: const Icon(Icons.close)),
        )),
        const SizedBox(height: 16),
        const Text('Пользователи', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (users.isEmpty) const Padding(padding: EdgeInsets.all(12),
          child: Text('Нет действующих пользователей', style: TextStyle(color: Colors.white54))),
        ...users.map((user) => Card(color: panel, margin: const EdgeInsets.only(top: 8),
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: [
            ListTile(
              title: Text(user['username'] ?? ''),
              subtitle: Text((user['status'] ?? '') + ' · выдан: ' + (user['createdAt'] ?? '—') + '\n' +
                (user['expiresAt'] ?? 'Без срока') + ' · ' + user['deviceCount'].toString() + '/' +
                user['maxDevices'].toString() + ' устройств'),
              isThreeLine: true,
            ),
            if (user['key'] != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SelectableText('Ключ: ' + user['key'])),
            Wrap(alignment: WrapAlignment.end, children: [
              IconButton(tooltip: 'Копировать ключ', onPressed: user['key'] == null ? null :
                () => Clipboard.setData(ClipboardData(text: user['key'])), icon: const Icon(Icons.copy, color: orange)),
              IconButton(tooltip: 'Изменить данные', onPressed: () => editUser(user), icon: const Icon(Icons.edit, color: orange)),
              IconButton(tooltip: 'Новый ключ', onPressed: () => setKey(user), icon: const Icon(Icons.key, color: orange)),
              IconButton(tooltip: user['status'] == 'blocked' ? 'Разблокировать' : 'Заблокировать',
                onPressed: () => toggleUser(user),
                icon: Icon(user['status'] == 'blocked' ? Icons.lock_open : Icons.block, color: orange)),
              IconButton(tooltip: 'Отозвать ключ', onPressed: () => revokeUser(user),
                icon: const Icon(Icons.key_off, color: Colors.redAccent)),
            ]),
          ])))),
        const SizedBox(height: 18),
        const Text('Отозванные ключи', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ...revokedUsers.map((user) => Card(color: panel, child: ListTile(
          title: Text(user['username'] ?? ''),
          subtitle: Text('Ключ отозван · запись создана ' + (user['createdAt'] ?? '—')),
          trailing: IconButton(tooltip: 'Удалить запись', onPressed: () => deleteRevoked(user),
            icon: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent)),
        ))),
        const SizedBox(height: 18),
        Row(children: [
          const Expanded(child: Text('Уведомления', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          TextButton.icon(onPressed: clearEvents, icon: const Icon(Icons.delete_sweep), label: const Text('Очистить')),
        ]),
        ...events.map((event) => ListTile(
          dense: true, contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.notifications_none, color: orange),
          title: Text(event['message'] ?? ''),
          subtitle: Text(event['createdAt'] ?? ''),
          trailing: IconButton(tooltip: 'Удалить уведомление', onPressed: () => deleteEvent(event),
            icon: const Icon(Icons.close, color: Colors.white54)),
        )),
        if (busy) const Center(child: Padding(padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(color: orange))),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 10),
          child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
      ],
    )),
  );

  Widget _stat(String title, dynamic value) => AnimatedContainer(
    duration: const Duration(milliseconds: 260), padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value.toString(), style: const TextStyle(color: orange, fontSize: 23, fontWeight: FontWeight.w800)),
      Text(title, style: const TextStyle(fontSize: 11, color: Colors.white70)),
    ]),
  );
}

