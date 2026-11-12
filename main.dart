import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sing_box/sing_box.dart';

const subscriptionUrl =
    'https://github.com/FLAT447/v2ray-lists/raw/refs/heads/main/BLACK_LTE.txt';
const refreshInterval = Duration(hours: 5);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SingBox.instance.initialize(const SingBoxOptions(
    android: SingBoxAndroidOptions(
      notificationTitle: 'IzviniteVpn',
      showTrafficInNotification: true,
      stopActionTitle: 'Отключить',
    ),
  ));
  runApp(const IzviniteVpnApp());
}

class IzviniteVpnApp extends StatelessWidget {
  const IzviniteVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0B1018);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IzviniteVpn',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF62A5FF),
          brightness: Brightness.dark,
          surface: const Color(0xFF151E2B),
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  Timer? _refreshTimer;
  StreamSubscription<SingBoxConnectionStatus>? _statusSub;
  StreamSubscription<SingBoxConnectionStats>? _statsSub;
  SingBoxConnectionStatus _status = SingBox.instance.status;
  String _message = 'Подписка ещё не загружена';
  String _lastUpdated = '—';
  String _latency = '—';
  String _download = '0 B/s';
  String _upload = '0 B/s';
  String? _subscription;
  DateTime? _updatedAt;
  bool _busy = false;

  bool get _connected => _status == SingBoxConnectionStatus.connected;
  bool get _connecting => _status == SingBoxConnectionStatus.connecting ||
      _status == SingBoxConnectionStatus.disconnecting;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusSub = SingBox.instance.watchConnectionStatus().listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _statsSub = SingBox.instance.watchConnectionStats().listen((s) {
      if (!mounted) return;
      setState(() {
        _download = _formatRate(s.downloadSpeed);
        _upload = _formatRate(s.uploadSpeed);
      });
    });
    _refreshIfDue();
    _refreshTimer = Timer.periodic(refreshInterval, (_) => _refreshSubscription());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshIfDue();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _statusSub?.cancel();
    _statsSub?.cancel();
    super.dispose();
  }

  String _formatRate(int bytes) {
    if (bytes < 1024) return '$bytes B/s';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  Future<void> _refreshIfDue() async {
    final last = _updatedAt;
    if (_subscription == null ||
        last == null ||
        DateTime.now().difference(last) >= refreshInterval) {
      await _refreshSubscription();
    }
  }

  Future<void> _refreshSubscription() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = 'Загружаю подписку…';
    });
    try {
      final response = await http.get(Uri.parse(subscriptionUrl)).timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final body = response.body.trim();
      if (body.isEmpty) throw Exception('Подписка пуста');
      _subscription = body;
      _updatedAt = DateTime.now();
      _lastUpdated = TimeOfDay.fromDateTime(_updatedAt!).format(context);
      _message = 'Подписка обновлена';
      if (_connected) {
        await SingBox.instance.connect(body);
        _message = 'Подписка обновлена, соединение перезапущено';
      }
    } catch (e) {
      _message = 'Не удалось обновить: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleVpn() async {
    if (_busy || _connecting) return;
    setState(() => _busy = true);
    try {
      if (_connected) {
        await SingBox.instance.disconnect();
        _message = 'Отключено';
      } else {
        var profile = _subscription;
        if (profile == null) {
          final response = await http.get(Uri.parse(subscriptionUrl)).timeout(
            const Duration(seconds: 25),
          );
          if (response.statusCode != 200) {
            throw Exception('Не удалось загрузить подписку: HTTP ${response.statusCode}');
          }
          profile = response.body.trim();
          if (profile.isEmpty) throw Exception('Подписка пуста');
          _subscription = profile;
          _updatedAt = DateTime.now();
          _lastUpdated = TimeOfDay.fromDateTime(_updatedAt!).format(context);
        }
        await SingBox.instance.connect(profile);
        _message = 'VPN подключён';
      }
    } catch (e) {
      _message = 'Ошибка: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkLatency() async {
    if (!_connected || _busy) {
      setState(() => _message = 'Сначала подключись к VPN');
      return;
    }
    setState(() {
      _busy = true;
      _message = 'Измеряю задержку через VPN…';
    });
    try {
      final result = await SingBox.instance.pingCurrentServer();
      if (mounted) {
        setState(() {
          _latency = '${result.ping} мс';
          _message = 'Проверка задержки завершена';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'Проверка не удалась: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _connected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('IzviniteVpn', style: TextStyle(fontWeight: FontWeight.w800)),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'О приложении',
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'IzviniteVpn',
              applicationVersion: '1.0.0',
              applicationLegalese: 'Автор: Юсупов И.\nVPN core: sing-box (GPL-3.0-or-later)',
            ),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1B2D47), Color(0xFF121C2A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: Colors.white.withOpacity(.07)),
              ),
              child: Column(
                children: [
                  Icon(
                    active ? Icons.shield_rounded : Icons.shield_outlined,
                    size: 58,
                    color: active ? const Color(0xFF69D7A2) : const Color(0xFF75B4FF),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    active ? 'Подключено' : (_connecting ? 'Подключение…' : 'Отключено'),
                    style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    active ? 'Трафик проходит через VPN' : 'BLACK LTE · одна подписка',
                    style: TextStyle(color: Colors.white.withOpacity(.62)),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton.icon(
                      onPressed: (_busy || _connecting) ? null : _toggleVpn,
                      icon: Icon(active ? Icons.stop_rounded : Icons.power_settings_new),
                      label: Text(active ? 'Отключиться' : 'Подключиться'),
                      style: FilledButton.styleFrom(
                        backgroundColor: active ? const Color(0xFFB94E59) : const Color(0xFF347FE0),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _panel(
              title: 'Подписка BLACK LTE',
              icon: Icons.cloud_sync_outlined,
              child: Column(
                children: [
                  _infoRow('Статус', _subscription == null ? 'Не загружена' : 'Загружена'),
                  _infoRow('Последнее обновление', _lastUpdated),
                  _infoRow('Автообновление', 'Каждые 5 часов'),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _refreshSubscription,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Обновить подписку'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _panel(
              title: 'Диагностика',
              icon: Icons.speed_outlined,
              child: Column(
                children: [
                  _infoRow('Реальная задержка', _latency),
                  _infoRow('Загрузка', _download),
                  _infoRow('Отдача', _upload),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _checkLatency,
                      icon: const Icon(Icons.network_check),
                      label: const Text('Проверить реальную задержку'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(.62), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text(
              'IzviniteVpn · Автор: Юсупов И.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(.35), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel({required String title, required IconData icon, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF151E2B),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: const Color(0xFF75B4FF)),
            const SizedBox(width: 9),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: Colors.white.withOpacity(.62)))),
          const SizedBox(width: 8),
          Flexible(child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
