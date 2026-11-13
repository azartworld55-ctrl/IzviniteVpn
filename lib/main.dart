import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sing_box/sing_box.dart';
import 'vpn_health.dart';

const apiUrl = String.fromEnvironment('API_BASE_URL');
const subUrl = 'https://github.com/FLAT447/v2ray-lists/raw/refs/heads/main/BLACK_LTE.txt';
const orange = Color(0xFFFF7A1A);
const panel = Color(0xFF1B1B1B);
final api = Api();
const secureStorage = FlutterSecureStorage();

Future<String?> readSubscriptionCache() async {
  try {
    final secure = await secureStorage.read(key: 'subscription_cache_black_lte');
    if (secure != null && secure.isNotEmpty) return secure;
  } catch (_) {
    // A lost/unavailable Keystore key must not prevent the legacy cache fallback.
  }
  final prefs = await SharedPreferences.getInstance();
  final legacy = prefs.getString('subscription_cache_black_lte');
  if (legacy != null && legacy.isNotEmpty) {
    try {
      await secureStorage.write(key: 'subscription_cache_black_lte', value: legacy);
      final verified = await secureStorage.read(key: 'subscription_cache_black_lte');
      if (verified == legacy) {
        await prefs.remove('subscription_cache_black_lte');
      }
    } catch (_) {
      // Keep the legacy copy unless the encrypted write was read back successfully.
    }
  }
  return legacy;
}

Future<void> clearSubscriptionCache() async {
  await secureStorage.delete(key: 'subscription_cache_black_lte');
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('subscription_cache_black_lte');
  await prefs.remove('subscription_cache_time_black_lte');
}



class SubscriptionLoadResult {
  final List<SingBoxServerConfig> servers;
  final bool fromCache;
  final String? updatedAt;
  const SubscriptionLoadResult(this.servers, this.fromCache, this.updatedAt);
}

Future<SubscriptionLoadResult> loadSubscriptionWithCache({
  required String subscriptionId,
  required String? downloadedBody,
  required String? contentType,
  required String? cachedBody,
}) async {
  Object? freshError;
  if (downloadedBody != null) {
    final body = downloadedBody.trim();
    final type = (contentType ?? '').toLowerCase();
    try {
      if (body.isEmpty || body.length > 2 * 1024 * 1024 ||
          type.contains('text/html') ||
          body.toLowerCase().startsWith('<!doctype html') ||
          body.toLowerCase().startsWith('<html')) {
        throw Exception('Источник подписки вернул пустой или некорректный ответ');
      }
      int? cachedServerCount;
      if (cachedBody != null && cachedBody.trim().isNotEmpty) {
        try {
          final previous = await SingBox.instance.importServerConfigs(
            cachedBody.trim(), subscriptionId: subscriptionId);
          cachedServerCount = previous.where((server) =>
            server.enabled && server.outbound != null).length;
        } catch (_) {
          // An unreadable old cache must not block a valid fresh subscription.
        }
      }
      final imported = await SingBox.instance.importServerConfigs(
        body, subscriptionId: subscriptionId);
      final usable = imported.where((server) =>
        server.enabled && server.outbound != null).toList();
      if (usable.isEmpty) throw Exception('В подписке нет поддерживаемых профилей');
      if (cachedServerCount != null && cachedServerCount > 0 &&
          usable.length < cachedServerCount * 0.5) {
        throw Exception('В новой подписке серверов меньше половины от кэша; сохраняем предыдущую версию');
      }
      await secureStorage.write(key: 'subscription_cache_black_lte', value: body);
      final prefs = await SharedPreferences.getInstance();
      final updatedAt = DateTime.now().toUtc().toIso8601String();
      await prefs.setString('subscription_cache_time_black_lte', updatedAt);
      return SubscriptionLoadResult(imported, false, updatedAt);
    } catch (e) {
      freshError = e;
    }
  }
  if (cachedBody != null && cachedBody.trim().isNotEmpty) {
    final imported = await SingBox.instance.importServerConfigs(
      cachedBody.trim(), subscriptionId: subscriptionId);
    final usable = imported.where((server) =>
      server.enabled && server.outbound != null).toList();
    if (usable.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      return SubscriptionLoadResult(imported, true,
        prefs.getString('subscription_cache_time_black_lte'));
    }
  }
  throw Exception('Не удалось загрузить подписку из сети или кэша: ${freshError ?? 'нет ответа'}');
}

class ApiUnavailableException implements Exception {
  final String message;
  const ApiUnavailableException(this.message);
  @override String toString() => message;
}

class Api {
  String? token;
  Uri uri(String p) => Uri.parse(apiUrl.replaceAll(RegExp(r'/$'), '') + '/api' + p);
  Map<String,String> get headers => {'Content-Type':'application/json', if(token != null) 'Authorization':'Bearer $token'};
  Future<Map<String,dynamic>> call(String method,String path,[Map<String,dynamic>? body]) async {
    if(apiUrl.isEmpty) throw const ApiUnavailableException('Сервер авторизации ещё не настроен.');
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
      throw const ApiUnavailableException('Сервер авторизации недоступен: превышено время ожидания.');
    } on http.ClientException {
      throw const ApiUnavailableException('Сервер авторизации недоступен. Проверь подключение к интернету.');
    }
    final d=r.body.isEmpty?<String,dynamic>{}:jsonDecode(r.body) as Map<String,dynamic>;
    if (r.statusCode >= 500) throw const ApiUnavailableException('Сервер авторизации временно недоступен.');
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

bool isRussianBootstrapServer(String name) {
  final value = name.toLowerCase();
  return value.contains('russia') ||
      value.contains('росси') ||
      value.contains('moscow') ||
      value.contains('москва') ||
      value.contains('🇷🇺') ||
      value.startsWith('ru-') ||
      value.contains('| ru');
}

class BootstrapPage extends StatefulWidget {
  const BootstrapPage({super.key});
  @override State<BootstrapPage> createState() => _BootstrapPageState();
}

class _BootstrapServerCheck {
  const _BootstrapServerCheck({
    required this.serverId,
    this.pingMs,
    this.exitIp,
    this.error,
  });
  final String serverId;
  final int? pingMs;
  final String? exitIp;
  final String? error;
  bool get working => error == null && pingMs != null && exitIp != null;
}

Future<String?> _fetchBootstrapIp() async {
  try {
    final response = await http.get(Uri.parse('https://api.ipify.org'))
        .timeout(const Duration(seconds: 3));
    final ip = response.body.trim();
    if (response.statusCode == 200 && InternetAddress.tryParse(ip) != null) {
      return ip;
    }
  } catch (_) {}
  return null;
}

class _BootstrapProbe {
  const _BootstrapProbe(this.latencyMs, this.ip);
  final int latencyMs;
  final String ip;
}

Future<_BootstrapProbe> _probeBootstrapTunnel() async {
  final watch = Stopwatch()..start();
  final response = await http.get(Uri.parse('https://api.ipify.org'))
      .timeout(const Duration(seconds: 4));
  watch.stop();
  final ip = response.body.trim();
  if (response.statusCode != 200 || InternetAddress.tryParse(ip) == null) {
    throw Exception('Нет ответа через VPN-туннель');
  }
  return _BootstrapProbe(watch.elapsedMilliseconds, ip);
}

class _BootstrapPageState extends State<BootstrapPage> {
  List<SingBoxServerConfig> servers = [];
  final Map<String, _BootstrapServerCheck> checks = {};
  String? selected;
  String? error;
  bool loading = true;
  bool scanning = false;
  bool connecting = false;
  int checkedCount = 0;
  int scanTotal = 0;
  String scanMessage = 'Загружаем список серверов…';

  @override void initState() {
    super.initState();
    loadBootstrapServers();
  }

  Future<void> loadBootstrapServers() async {
    if (mounted) setState(() {
      loading = true; scanning = false; checkedCount = 0; scanTotal = 0;
      checks.clear(); servers = []; selected = null;
      error = null; scanMessage = 'Загружаем список серверов…';
    });
    try {
      http.Response? response;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final candidate = await http.get(Uri.parse(subUrl), headers: const {
            'Accept': 'text/plain, */*', 'Cache-Control': 'no-cache',
            'User-Agent': 'IzviniteVpn/2.0',
          }).timeout(const Duration(seconds: 12));
          if (candidate.statusCode == 200) { response = candidate; break; }
        } on TimeoutException { } on http.ClientException { }
        if (attempt < 2) await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
      final loaded = await loadSubscriptionWithCache(
        subscriptionId: 'black-lte',
        downloadedBody: response?.body,
        contentType: response?.headers['content-type'],
        cachedBody: await readSubscriptionCache(),
      );
      final eligible = loaded.servers.where((server) =>
        server.enabled && server.outbound != null &&
        !isRussianBootstrapServer(server.name)).take(30).toList();
      if (eligible.isEmpty) {
        throw Exception('В подписке не найдено подходящих серверов вне РФ');
      }
      if (mounted) setState(() {
        servers = eligible;
        scanTotal = eligible.length;
        loading = false; scanning = true;
        scanMessage = 'Ищем три работающих сервера…';
        final cachedAt = DateTime.tryParse(loaded.updatedAt ?? '')?.toLocal();
        error = loaded.fromCache
          ? 'Используется сохранённый список; обновлён: ' +
              (cachedAt?.toString() ?? 'дата неизвестна') + '.'
          : null;
      });
      await checkBootstrapServers(eligible);
    } catch (e) {
      if (mounted) setState(() {
        error = 'Не удалось загрузить стартовые серверы: ' + e.toString();
        loading = false; scanning = false;
      });
    }
  }

  Future<void> checkBootstrapServers(List<SingBoxServerConfig> candidates) async {
    final box = SingBox.instance;
    final baselineIp = await _fetchBootstrapIp();
    var workingCount = 0;

    for (var index = 0; index < candidates.length && workingCount < 3; index++) {
      final server = candidates[index];
      if (!mounted) return;
      setState(() {
        scanMessage = 'Проверяем сервер ' + (index + 1).toString() + ' из ' +
          candidates.length.toString() + ': ' + server.name;
      });

      _BootstrapServerCheck result;
      try {
        await box.connectToServers([server], selectedId: server.id)
            .timeout(const Duration(seconds: 7));
        await box.waitForStatus(SingBoxConnectionStatus.connected)
            .timeout(const Duration(seconds: 7));

        // One small HTTPS request through the active system tunnel. Its
        // elapsed time is the connectivity latency; no large speed test runs
        // during bootstrap discovery.
        final probe = await _probeBootstrapTunnel();
        final sameIp = baselineIp != null && baselineIp == probe.ip;
        result = _BootstrapServerCheck(
          serverId: server.id,
          pingMs: probe.latencyMs,
          exitIp: probe.ip,
          error: sameIp
              ? 'Внешний IP не изменился — VPN-маршрут не подтверждён'
              : null,
        );
      } catch (e) {
        result = _BootstrapServerCheck(
          serverId: server.id,
          error: e.toString().replaceFirst('Exception: ', ''),
        );
      } finally {
        try {
          if (box.status != SingBoxConnectionStatus.disconnected) {
            await box.disconnect().timeout(const Duration(seconds: 3));
            await box.waitForStatus(SingBoxConnectionStatus.disconnected)
                .timeout(const Duration(seconds: 3));
          }
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        checks[server.id] = result;
        checkedCount = index + 1;
        if (result.working) {
          workingCount++;
          if (selected == null) selected = server.id;
        }
      });
    }

    if (!mounted) return;
    setState(() {
      servers = candidates.where((server) => checks[server.id]?.working == true).toList();
      selected = servers.isEmpty ? null : (servers.any((s) => s.id == selected)
          ? selected : servers.first.id);
      scanning = false;
      scanMessage = workingCount == 3
          ? 'Найдены три работающих сервера'
          : 'Найдено работающих серверов: ' + workingCount.toString();
      if (workingCount < 3) {
        error = 'Удалось подтвердить только ' + workingCount.toString() +
            ' из 3 серверов. Авторизация не начнётся, пока не будут найдены три.';
      }
    });
  }

  Future<void> connectAndContinue() async {
    if (connecting || scanning || servers.length < 3 || selected == null) return;
    final selectedCheck = checks[selected!];
    if (selectedCheck == null || !selectedCheck.working) {
      setState(() => error = 'Выберите сервер, который прошёл проверку.');
      return;
    }
    setState(() { connecting = true; error = null; });
    try {
      final server = servers.firstWhere((item) => item.id == selected);
      await SingBox.instance.connectToServers([server], selectedId: server.id);
      await SingBox.instance.waitForStatus(SingBoxConnectionStatus.connected);
      if (api.token != null) {
        try {
          final me = await api.call('GET', '/auth/me');
          if (!mounted) return;
          Navigator.pushReplacement(context, MaterialPageRoute(
            builder: (_) => me['user']?['role'] == 'admin'
              ? const AdminPage() : const HomePage()));
          return;
        } on ApiUnavailableException {
          rethrow;
        } catch (_) {
          final p = await SharedPreferences.getInstance();
          await p.remove('session_token');
          api.token = null;
        }
      }
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось подключиться к выбранному серверу: ' + e.toString());
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Widget _serverCard(SingBoxServerConfig server) {
    final result = checks[server.id];
    final isSelected = selected == server.id;
    final title = result == null ? 'Ожидает проверки' :
      result.error != null ? 'Не прошёл проверку' : 'Работает';
    return Card(
      color: panel,
      child: RadioListTile<String>(
        value: server.id,
        groupValue: selected,
        onChanged: scanning || connecting || result?.working != true
          ? null : (value) => setState(() { selected = value; error = null; }),
        activeColor: orange,
        title: Text(server.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: result == null ? Colors.white60 :
              result.working ? Colors.lightGreenAccent : Colors.redAccent)),
            if (result?.pingMs != null) Text('Задержка: ' + result!.pingMs.toString() + ' мс'),
            if (result?.exitIp != null) Text('Внешний IP: ' + result!.exitIp!),
            if (result?.error != null) Text(result!.error!,
              style: const TextStyle(color: Colors.redAccent)),
            if (isSelected && result?.working == true)
              const Text('Выбран', style: TextStyle(color: orange)),
          ]),
        ),
      ),
    );
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Проверка VPN перед входом')),
    body: ListView(padding: const EdgeInsets.all(22), children: [
      const Icon(Icons.shield_outlined, color: orange, size: 64),
      const SizedBox(height: 14),
      const Text('Выберите проверенный VPN',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      const Text('Приложение проверяет серверы из подписки по очереди и оставляет три, через которые действительно проходит соединение. Измеряется задержка HTTPS-запроса через VPN.',
        textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
      const SizedBox(height: 20),
      if (loading) ...[
        const Center(child: CircularProgressIndicator(color: orange)),
        const SizedBox(height: 10),
        const Text('Загружаем список из трёх серверов…', textAlign: TextAlign.center),
      ],
      if (scanning) ...[
        Row(children: [
          const SizedBox(width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: orange)),
          const SizedBox(width: 12),
          Expanded(child: Text(scanMessage)),
        ]),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: servers.isEmpty ? null : checkedCount / servers.length,
          color: orange, backgroundColor: Colors.white12,
        ),
        const SizedBox(height: 6),
        Text('Проверено ' + checkedCount.toString() + ' из ' + scanTotal.toString(),
          textAlign: TextAlign.end,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
      if (!loading && (servers.isEmpty || (!scanning && servers.length < 3)))
        FilledButton.tonal(onPressed: loadBootstrapServers,
          child: const Text('Повторить загрузку серверов')),
      ...servers.map(_serverCard),
      if (!scanning && servers.length < 3)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Ни один сервер не прошёл проверку. Попробуйте обновить список позже.',
            style: TextStyle(color: Colors.redAccent)),
        ),
      if (error != null) Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: loading || scanning || connecting || selected == null ||
            checks[selected]?.working != true || apiUrl.isEmpty
          ? null : connectAndContinue,
        style: FilledButton.styleFrom(backgroundColor: orange, foregroundColor: Colors.black),
        child: Text(connecting ? 'Подключение…' :
          scanning ? 'Идёт проверка серверов…' : 'Подключиться и продолжить'),
      ),
      if (apiUrl.isEmpty) const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('Адрес сервера авторизации не настроен.',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.redAccent)),
      ),
    ]),
  );
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
  bool loading = true;
  String? error;
  @override void initState() { super.initState(); restore(); }
  Future<void> restore() async {
    if (mounted) setState(() { loading = true; error = null; });
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('session_token');
    if (saved != null) {
      api.token = saved;
      try {
        final me = await api.call('GET', '/auth/me');
        if (!mounted) return;
        openUser(me['user']);
        return;
      } on ApiUnavailableException {
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const BootstrapPage()));
        return;
      } catch (_) {
        await p.remove('session_token');
        api.token = null;
      }
    }
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const BootstrapPage()));
  }
  void openUser(dynamic user) {
    Navigator.pushReplacement(context, MaterialPageRoute(
      builder: (_) => user['role'] == 'admin' ? const AdminPage() : const HomePage()));
  }
  @override Widget build(BuildContext c) => Scaffold(
    body: Center(child: loading
      ? const CircularProgressIndicator(color: orange)
      : Padding(padding: const EdgeInsets.all(28), child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_rounded, color: orange, size: 44),
            const SizedBox(height: 14),
            const Text('Сервер авторизации недоступен', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(error ?? 'Проверь подключение к интернету.', textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 18),
            FilledButton(onPressed: restore, child: const Text('Повторить')),
          ],
        ))));
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
  Future<void> logout() async {
    try { await SingBox.instance.disconnect(); } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_token');
    await clearSubscriptionCache();
    api.token = null;
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const BootstrapPage()), (_) => false);
    }
  }

  Future<bool> ensureSession() async {
    if (_checkingSession || !mounted) return true;
    if (api.token == null) return false;
    _checkingSession = true;
    try {
      await api.call('GET', '/auth/me');
      return true;
    } catch (e) {
      if (e is ApiUnavailableException) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)));
        return false;
      }
      try { await SingBox.instance.disconnect(); } catch (_) {}
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
  StreamSubscription<dynamic>? statsSub, statusSub, stateSub, groupsSub, logSub;
  String down = '0 B/s', up = '0 B/s';
  String? error, vpnError, coreDiagnostic, selected, activeServer;
  bool loadingSubscription = false, connecting = false;
  bool isAdmin = false, disconnectingNow = false;
  late final VpnHealthController healthController;
  SingBoxConnectionStatus vpnStatus = SingBox.instance.status;

  bool get connected => vpnStatus == SingBoxConnectionStatus.connected;
  bool get busy => connecting || loadingSubscription;

  // Mirror sing_box.connectToServers() tag generation so duplicate display
  // names still map back to their stable profile IDs.
  Map<String, SingBoxServerConfig> get _serverByOutboundTag {
    final result = <String, SingBoxServerConfig>{};
    final usedTags = <String>{SingBoxConfigBuilder.proxyTag, SingBoxConfigBuilder.autoTag, SingBoxConfigBuilder.directTag};
    for (final server in servers) {
      if (!server.enabled || server.outbound == null) continue;
      var tag = server.name.isNotEmpty ? server.name : server.id;
      if (usedTags.contains(tag)) {
        var index = 2;
        while (usedTags.contains('$tag ($index)')) { index++; }
        tag = '$tag ($index)';
      }
      usedTags.add(tag);
      result[tag] = server;
    }
    return result;
  }

  @override void initState() {
    super.initState();
    startSessionWatch();
    healthController = VpnHealthController()..start();
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
      final proxyGroups = groups.where((item) => item.tag == SingBoxConfigBuilder.proxyTag).toList();
      if (proxyGroups.isEmpty) return;
      var value = proxyGroups.first.selected.toString();
      if (value == SingBoxConfigBuilder.autoTag) {
        final autoGroups = groups.where((item) => item.tag == SingBoxConfigBuilder.autoTag).toList();
        if (autoGroups.isNotEmpty) value = autoGroups.first.selected.toString();
      }
      if (value.isEmpty || value == SingBoxConfigBuilder.autoTag || !mounted) return;
      final server = _serverByOutboundTag[value];
      setState(() {
        activeServer = value;
        if (server != null) selected = server.id;
      });
    });
    statsSub = SingBox.instance.watchConnectionStats().listen((stats) {
      if (!mounted) return;
      setState(() {
        down = rate(stats.downloadSpeed);
        up = rate(stats.uploadSpeed);
      });
    });
    logSub = SingBox.instance.watchLogs().listen((entry) {
      if (entry.level.index >= SingBoxLogLevel.warn.index && mounted) {
        setState(() => coreDiagnostic = entry.plainMessage);
      }
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
    final byFlag = <String, String>{
      '🇩🇪':'Германия','🇳🇱':'Нидерланды','🇫🇷':'Франция','🇬🇧':'Великобритания',
      '🇺🇸':'США','🇫🇮':'Финляндия','🇸🇪':'Швеция','🇳🇴':'Норвегия',
      '🇨🇭':'Швейцария','🇵🇱':'Польша','🇦🇹':'Австрия','🇧🇪':'Бельгия',
      '🇪🇸':'Испания','🇮🇹':'Италия','🇨🇦':'Канада','🇯🇵':'Япония',
      '🇸🇬':'Сингапур','🇹🇷':'Турция','🇱🇻':'Латвия','🇪🇪':'Эстония',
      '🇱🇹':'Литва','🇷🇴':'Румыния','🇧🇬':'Болгария','🇭🇰':'Гонконг',
      '🇰🇷':'Южная Корея','🇦🇺':'Австралия','🇷🇺':'Россия','🇺🇦':'Украина',
    };
    final flag = flagFor(name);
    return byFlag[flag] ?? (cleaned.isEmpty ? 'Сервер' : cleaned);
  }

  Future<void> loadServers() async {
    if (loadingSubscription || connecting) return;
    if (mounted) setState(() { loadingSubscription = true; error = null; });
    try {
      http.Response? response;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final candidate = await http.get(Uri.parse(subUrl), headers: const {
            'Accept': 'text/plain, application/json;q=0.9, */*;q=0.8',
            'Cache-Control': 'no-cache', 'User-Agent': 'IzviniteVpn/1.1',
          }).timeout(const Duration(seconds: 25));
          if (candidate.statusCode == 200) { response = candidate; break; }
        } on TimeoutException { }
          on http.ClientException { }
        if (attempt < 2) await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
      final loadedResult = await loadSubscriptionWithCache(
        subscriptionId: 'black-lte',
        downloadedBody: response?.body,
        contentType: response?.headers['content-type'],
        cachedBody: await readSubscriptionCache(),
      );
      final loaded = loadedResult.servers;
      if (mounted) setState(() {
        // The BLACK_LTE feed is the source for every VPN screen. Keep only
        // supported non-Russian nodes consistently, not just during bootstrap.
        servers = loaded.where((server) =>
          server.enabled && server.outbound != null &&
          !isRussianBootstrapServer(server.name)).toList();
        if (servers.isEmpty) throw Exception('В BLACK_LTE не найдено доступных серверов вне РФ');
        if (selected == null || !servers.any((server) => server.id == selected)) {
          selected = servers.first.id;
        }
        final cachedAt = DateTime.tryParse(loadedResult.updatedAt ?? '')?.toLocal();
        error = loadedResult.fromCache
          ? 'Показана сохранённая подписка; обновлена: ${cachedAt?.toString() ?? 'дата неизвестна'}.'
          : null;
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось обновить подписку: ' + e.toString());
    } finally {
      if (mounted) setState(() => loadingSubscription = false);
    }
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
    setState(() { connecting = true; vpnError = null; coreDiagnostic = null; });
    try {
      final selectedId = auto ? null : (selected ?? servers.first.id);
      await SingBox.instance.connectToServers(servers, selectedId: selectedId);
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
    setState(() { connecting = true; disconnectingNow = true; vpnError = null; });
    try {
      await SingBox.instance.disconnect();
      if (mounted) setState(() => activeServer = null);
    } catch (e) {
      if (mounted) setState(() => vpnError = e.toString());
    } finally {
      if (mounted) setState(() { connecting = false; disconnectingNow = false; });
    }
  }

  Future<void> chooseServer(SingBoxServerConfig server) async {
    if (connecting) return;
    HapticFeedback.selectionClick();
    setState(() { selected = server.id; if (connected) connecting = true; vpnError = null; });
    try {
      if (connected) {
        // Resolve the plugin-generated tag from the stable profile ID. This
        // keeps switching instant and handles duplicate display names.
        String? outboundTag;
        for (final entry in _serverByOutboundTag.entries) {
          if (entry.value.id == server.id) { outboundTag = entry.key; break; }
        }
        if (outboundTag == null) throw Exception('Не удалось найти сервер в активной конфигурации.');
        await SingBox.instance.selectOutbound(SingBoxConfigBuilder.proxyTag, outboundTag);
        if (mounted) setState(() => activeServer = outboundTag);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => vpnError = e.toString());
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  @override void dispose() {
    statsSub?.cancel();
    statusSub?.cancel();
    stateSub?.cancel();
    groupsSub?.cancel();
    logSub?.cancel();
    healthController.dispose();
    super.dispose();
  }

  String get statusLabel {
    if (disconnectingNow) return 'Отключение…';
    if (connecting && vpnStatus != SingBoxConnectionStatus.connected) return 'Подключение…';
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
          IconButton(
            tooltip: 'Выйти из аккаунта',
            onPressed: logout,
            icon: const Icon(Icons.logout),
          ),
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
        VpnHealthCard(controller: healthController),
        if (loadingSubscription) const Padding(padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator(color: orange))),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
        if (vpnError != null) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(vpnError!, style: const TextStyle(color: Colors.redAccent))),
        if (coreDiagnostic != null) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text('Диагностика sing-box: $coreDiagnostic', style: const TextStyle(color: Colors.orangeAccent, fontSize: 12))),
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
              TextButton.icon(onPressed: loadingSubscription ? null : () async { await loadServers(); refreshSheet(() {}); },
                icon: const Icon(Icons.refresh, size: 18), label: const Text('Обновить подписку')),
            ],
          )),
          if (loadingSubscription) const Padding(padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(color: orange)),
          Expanded(child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 18),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.2),
            itemCount: servers.length,
            itemBuilder: (context, index) {
              final server = servers[index];
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
                    Text(chosen ? 'Выбран' : 'Нажмите, чтобы выбрать',
                      style: const TextStyle(fontSize: 12, color: Colors.white54)),
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
      IconButton(tooltip: 'Выйти из аккаунта', onPressed: logout, icon: const Icon(Icons.logout)),
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
        const Text('Активные пользователи', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ...users.where((u) => u['status'] == 'active').map(_userCard),
        const SizedBox(height: 14),
        const Text('Заблокированные пользователи', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ...users.where((u) => u['status'] == 'blocked').map(_userCard),
        const SizedBox(height: 14),
        const Text('Истёкший срок', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ...users.where((u) => u['status'] == 'expired').map(_userCard),
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

  Widget _userCard(dynamic user) => Card(
    color: panel, margin: const EdgeInsets.only(top: 8),
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
    ])),
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
