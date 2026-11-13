import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sing_box/sing_box.dart';

enum VpnHealth {
  disconnected,
  connecting,
  checking,
  working,
  noTraffic,
  possibleLeak,
  error,
}

const _ipEndpoints = <String>[
  'https://api.ipify.org',
  'https://icanhazip.com',
  'https://ifconfig.me/ip',
];

Future<String?> fetchExternalIp() async {
  for (final endpoint in _ipEndpoints) {
    try {
      final response = await http
          .get(Uri.parse(endpoint))
          .timeout(const Duration(seconds: 6));
      final value = response.body.trim();
      if (response.statusCode == 200 &&
          InternetAddress.tryParse(value) != null) {
        return value;
      }
    } catch (_) {
      // Try the next independent IP endpoint.
    }
  }
  return null;
}

class VpnSpeedResult {
  const VpnSpeedResult({
    required this.downloadMbps,
    required this.uploadMbps,
    required this.measuredAt,
  });

  final double downloadMbps;
  final double uploadMbps;
  final DateTime measuredAt;
}

class VpnHealthController extends ChangeNotifier {
  VpnHealthController({SingBox? singBox})
      : _singBox = singBox ?? SingBox.instance;

  final SingBox _singBox;

  VpnHealth health = VpnHealth.disconnected;
  int? pingMs;
  String? exitIp;
  String? realIp;
  String? errorText;
  String? speedError;
  double liveDownloadMbps = 0;
  double liveUploadMbps = 0;
  VpnSpeedResult? lastSpeed;
  bool speedRunning = false;

  StreamSubscription<dynamic>? _statusSub;
  StreamSubscription<dynamic>? _statsSub;
  StreamSubscription<dynamic>? _stateSub;
  Timer? _recheckTimer;
  int _generation = 0;
  bool _started = false;
  bool _capturingBaseline = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool get isConnected =>
      _singBox.status == SingBoxConnectionStatus.connected;

  void start() {
    if (_started) return;
    _started = true;

    _statusSub = _singBox.watchConnectionStatus().listen((status) {
      if (!_disposed) _onStatus(status);
    });
    _stateSub = _singBox.watchConnectionState().listen((state) {
      if (_disposed || state.error == null) return;
      errorText = state.error.toString();
      health = VpnHealth.error;
      _notify();
    });
    _statsSub = _singBox.watchConnectionStats().listen((stats) {
      if (_disposed) return;
      if (!isConnected) {
        liveDownloadMbps = 0;
        liveUploadMbps = 0;
      } else {
        liveDownloadMbps = stats.downloadSpeed * 8 / 1000000;
        liveUploadMbps = stats.uploadSpeed * 8 / 1000000;
      }
      _notify();
    });

    if (_singBox.status == SingBoxConnectionStatus.disconnected) {
      _captureRealIp();
    }
    _onStatus(_singBox.status);
  }

  void _onStatus(SingBoxConnectionStatus status) {
    if (status == SingBoxConnectionStatus.disconnected ||
        status == SingBoxConnectionStatus.disconnecting) {
      _generation++;
      _recheckTimer?.cancel();
      health = VpnHealth.disconnected;
      pingMs = null;
      exitIp = null;
      liveDownloadMbps = 0;
      liveUploadMbps = 0;
      errorText = null;
      if (status == SingBoxConnectionStatus.disconnected) {
        _captureRealIp();
      }
    } else if (status == SingBoxConnectionStatus.connecting) {
      _generation++;
      _recheckTimer?.cancel();
      health = VpnHealth.connecting;
    } else if (status == SingBoxConnectionStatus.connected) {
      verify();
      _recheckTimer?.cancel();
      _recheckTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _pingOnly(),
      );
    }
    _notify();
  }

  Future<void> _captureRealIp() async {
    if (_capturingBaseline || realIp != null) return;
    _capturingBaseline = true;
    try {
      final ip = await fetchExternalIp();
      // Only save an address obtained while the tunnel is disconnected.
      if (_singBox.status == SingBoxConnectionStatus.disconnected) {
        realIp = ip;
      }
    } finally {
      _capturingBaseline = false;
      _notify();
    }
  }

  Future<int?> _ping() async {
    try {
      final result = await _singBox.pingCurrentServer();
      return result.success ? result.ping.round() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pingOnly() async {
    if (!isConnected) return;
    final generation = _generation;
    final result = await _ping();
    if (generation != _generation || !isConnected) return;
    pingMs = result;
    if (result == null) {
      health = VpnHealth.noTraffic;
    } else if (health == VpnHealth.noTraffic) {
      health = VpnHealth.working;
    }
    _notify();
  }

  Future<void> verify() async {
    if (!isConnected) return;
    final generation = ++_generation;
    health = VpnHealth.checking;
    errorText = null;
    _notify();

    final pingFuture = _ping();
    final ipFuture = fetchExternalIp();
    final ping = await pingFuture;
    final ip = await ipFuture;

    if (generation != _generation || !isConnected) return;

    pingMs = ping;
    exitIp = ip;

    if (ping == null) {
      health = VpnHealth.noTraffic;
    } else if (ip != null && realIp != null && ip == realIp) {
      // An unchanged IP can indicate bypass routing, but is not proof of a leak.
      health = VpnHealth.possibleLeak;
    } else {
      health = VpnHealth.working;
    }
    _notify();
  }

  Future<void> runSpeedTest() async {
    if (!isConnected || speedRunning) return;
    speedRunning = true;
    speedError = null;
    _notify();

    try {
      final result = await _singBox.testSpeed();
      if (_disposed) return;
      lastSpeed = VpnSpeedResult(
        downloadMbps: result.downloadMbps,
        uploadMbps: result.uploadMbps,
        measuredAt: DateTime.now(),
      );
    } catch (error) {
      speedError = error.toString();
    } finally {
      speedRunning = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _recheckTimer?.cancel();
    _statusSub?.cancel();
    _statsSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }
}

class VpnHealthCard extends StatelessWidget {
  const VpnHealthCard({super.key, required this.controller});

  final VpnHealthController controller;

  String _label(VpnHealth health) {
    switch (health) {
      case VpnHealth.disconnected:
        return 'VPN выключен';
      case VpnHealth.connecting:
        return 'Подключение…';
      case VpnHealth.checking:
        return 'Проверяем соединение…';
      case VpnHealth.working:
        return 'VPN работает';
      case VpnHealth.noTraffic:
        return 'Подключено, но трафик не проходит';
      case VpnHealth.possibleLeak:
        return 'Внешний IP не изменился — проверьте маршрутизацию';
      case VpnHealth.error:
        return 'Ошибка VPN';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final c = controller;
        final connected = c.isConnected;
        return Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B1B),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ПРОВЕРКА СОЕДИНЕНИЯ',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _label(c.health),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              _line('Внешний IP', c.exitIp ?? '—'),
              _line('Задержка', c.pingMs == null ? '—' : '${c.pingMs} мс'),
              _line(
                'Сейчас',
                '↓ ${c.liveDownloadMbps.toStringAsFixed(1)} · '
                    '↑ ${c.liveUploadMbps.toStringAsFixed(1)} Мбит/с',
              ),
              if (c.errorText != null && c.health == VpnHealth.error)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    c.errorText!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              if (c.lastSpeed != null) ...[
                const Divider(height: 22, color: Colors.white12),
                _line(
                  'Последний замер',
                  '↓ ${c.lastSpeed!.downloadMbps.toStringAsFixed(1)} · '
                      '↑ ${c.lastSpeed!.uploadMbps.toStringAsFixed(1)} Мбит/с',
                ),
                _line(
                  'Время',
                  '${c.lastSpeed!.measuredAt.hour.toString().padLeft(2, '0')}:'
                      '${c.lastSpeed!.measuredAt.minute.toString().padLeft(2, '0')}',
                ),
              ],
              if (c.speedError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Не удалось измерить скорость: ${c.speedError}',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: !connected || c.speedRunning
                        ? null
                        : c.runSpeedTest,
                    child: Text(
                      c.speedRunning ? 'Измеряем…' : 'Проверить скорость',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: !connected || c.health == VpnHealth.checking
                        ? null
                        : c.verify,
                    child: const Text('Перепроверить'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Тест скорости расходует интернет-трафик.',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white60)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
