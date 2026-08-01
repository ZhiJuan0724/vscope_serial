import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/ssh_connection_config.dart';
import '../../services/app_settings.dart';
import '../../services/ssh_connection_service.dart';
import '../widgets/common_widgets.dart';

Future<void> showSshConnectionDialog(BuildContext context) => showDialog(
  context: context,
  builder: (context) => const SshConnectionDialog(),
);

class SshConnectionDialog extends StatefulWidget {
  const SshConnectionDialog({super.key});

  @override
  State<SshConnectionDialog> createState() => _SshConnectionDialogState();
}

class _SshConnectionDialogState extends State<SshConnectionDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _privateKey;
  final TextEditingController _password = TextEditingController();
  final TextEditingController _passphrase = TextEditingController();
  late SshAuthenticationMode _authenticationMode;
  bool _obscurePassword = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = AppSettings().sshConnectionConfig;
    _host = TextEditingController(text: config.host);
    _port = TextEditingController(text: '${config.port}');
    _username = TextEditingController(text: config.username);
    _privateKey = TextEditingController(text: config.privateKeyPath);
    _authenticationMode = config.authenticationMode;
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _privateKey.dispose();
    _password.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  SshConnectionConfig? _readConfig() {
    final port = int.tryParse(_port.text.trim());
    if (_host.text.trim().isEmpty ||
        _username.text.trim().isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535) {
      setState(() => _error = '请填写有效的主机、端口和用户名');
      return null;
    }
    if (_authenticationMode == SshAuthenticationMode.privateKey &&
        _privateKey.text.trim().isEmpty) {
      setState(() => _error = '请选择 SSH 私钥文件');
      return null;
    }
    return SshConnectionConfig(
      host: _host.text.trim(),
      port: port,
      username: _username.text.trim(),
      authenticationMode: _authenticationMode,
      privateKeyPath: _privateKey.text.trim(),
    );
  }

  Future<void> _connect() async {
    final config = _readConfig();
    if (config == null) return;
    final settings = AppSettings()..sshConnectionConfig = config;
    await settings.save();
    if (!mounted) return;
    final service = context.read<SshConnectionService>();
    final secrets = SshConnectionSecrets(
      password:
          _authenticationMode == SshAuthenticationMode.password
              ? _password.text
              : null,
      privateKeyPassphrase:
          _authenticationMode == SshAuthenticationMode.privateKey
              ? _passphrase.text
              : null,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _connectWithTrust(service, config, secrets);
      if (mounted && service.isConnected) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectWithTrust(
    SshConnectionService service,
    SshConnectionConfig config,
    SshConnectionSecrets secrets,
  ) async {
    final settings = AppSettings();
    final trusted = settings.sshKnownHosts[config.endpointKey];
    try {
      await service.connect(config, secrets, trustedHost: trusted);
    } on SshHostKeyVerificationRequired catch (verification) {
      if (!mounted) rethrow;
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => AlertDialog(
              title: Text(verification.changed ? 'SSH 主机密钥已变化' : '确认 SSH 主机密钥'),
              content: SelectableText(
                '${verification.changed ? '已保存的主机密钥与本次连接不一致。确认服务器身份后才能替换。' : '首次连接该主机，请核对服务器显示的指纹。'}\n\n'
                '算法：${verification.algorithm}\n'
                '指纹：${verification.fingerprint}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style:
                      verification.changed
                          ? FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                          )
                          : null,
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(verification.changed ? '替换并连接' : '信任并连接'),
                ),
              ],
            ),
      );
      if (accepted != true) throw StateError('用户取消了 SSH 主机密钥确认');
      settings.sshKnownHosts = {
        ...settings.sshKnownHosts,
        config.endpointKey: SshKnownHost(
          algorithm: verification.algorithm,
          fingerprint: verification.fingerprint,
        ),
      };
      await settings.save();
      await service.connect(
        config,
        secrets,
        trustedHost: settings.sshKnownHosts[config.endpointKey],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<SshConnectionService>();
    final locked = _busy || service.isConnecting || service.isConnected;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: const Text('SSH 连接配置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: _field(_host, '主机', enabled: !locked)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 110,
                    child: _field(_port, '端口', enabled: !locked),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _field(_username, '用户名', enabled: !locked),
              const SizedBox(height: 12),
              NoAnimDropdown<SshAuthenticationMode>(
                value: _authenticationMode,
                hint: '认证方式',
                decoration: const InputDecoration(
                  labelText: '认证方式',
                  border: OutlineInputBorder(),
                ),
                items:
                    SshAuthenticationMode.values
                        .map(
                          (mode) => DropdownMenuItem(
                            value: mode,
                            child: Text(mode.label),
                          ),
                        )
                        .toList(),
                onChanged:
                    locked
                        ? null
                        : (value) {
                          if (value != null) {
                            setState(() => _authenticationMode = value);
                          }
                        },
              ),
              const SizedBox(height: 12),
              if (_authenticationMode == SshAuthenticationMode.password)
                TextField(
                  controller: _password,
                  enabled: !locked,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: '密码（不会保存）',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      onPressed:
                          () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                )
              else ...[
                TextField(
                  controller: _privateKey,
                  enabled: !locked,
                  decoration: InputDecoration(
                    labelText: 'PEM 私钥文件',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: '选择私钥文件',
                      onPressed:
                          locked
                              ? null
                              : () async {
                                final result = await FilePicker.pickFiles(
                                  dialogTitle: '选择 SSH 私钥文件',
                                  type: FileType.any,
                                  lockParentWindow: true,
                                );
                                final path = result?.files.single.path;
                                if (path != null && mounted) {
                                  setState(() => _privateKey.text = path);
                                }
                              },
                      icon: const Icon(Icons.folder_open),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passphrase,
                  enabled: !locked,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '私钥口令（可选，不会保存）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: locked ? null : () => unawaited(_connect()),
          icon:
              _busy
                  ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.link),
          label: Text(_busy ? '连接中' : '连接'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required bool enabled,
  }) => TextField(
    controller: controller,
    enabled: enabled,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );
}
