import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/ssh_connection_config.dart';
import '../../services/app_settings.dart';
import '../../services/ssh_connection_service.dart';
import '../../services/ssh_password_store.dart';
import '../widgets/common_widgets.dart';

Future<void> showSshConnectionDialog(BuildContext context) => showDialog(
  context: context,
  builder: (context) => const SshConnectionDialog(),
);

class SshConnectionDialog extends StatefulWidget {
  const SshConnectionDialog({
    super.key,
    this.passwordStore = const WindowsSshPasswordStore(),
  });

  final SshPasswordStore passwordStore;

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
  bool _savePassword = false;
  bool _busy = false;
  String? _error;
  Timer? _configSaveTimer;
  Future<void> _pendingConfigSave = Future<void>.value();
  late SshConnectionConfig _lastValidConfig;

  @override
  void initState() {
    super.initState();
    final config = AppSettings().sshConnectionConfig;
    _lastValidConfig = config;
    _host = TextEditingController(text: config.host);
    _port = TextEditingController(text: '${config.port}');
    _username = TextEditingController(text: config.username);
    _privateKey = TextEditingController(text: config.privateKeyPath);
    _authenticationMode = config.authenticationMode;
    _savePassword = config.savePassword;
    if (_authenticationMode == SshAuthenticationMode.password &&
        _savePassword) {
      try {
        _password.text = widget.passwordStore.read(config) ?? '';
      } catch (error) {
        _error = '无法读取已保存的 SSH 密码：$error';
      }
    }
    for (final controller in [_host, _port, _username, _privateKey]) {
      controller.addListener(_scheduleConfigSave);
    }
  }

  @override
  void dispose() {
    _configSaveTimer?.cancel();
    final config = _buildConfig();
    if (config != null) unawaited(_queueConfigSave(config));
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _privateKey.dispose();
    _password.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  SshConnectionConfig? _buildConfig() {
    final port = int.tryParse(_port.text.trim());
    if (_host.text.trim().isEmpty ||
        _username.text.trim().isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        (_authenticationMode == SshAuthenticationMode.privateKey &&
            _privateKey.text.trim().isEmpty)) {
      return null;
    }
    return SshConnectionConfig(
      host: _host.text.trim(),
      port: port,
      username: _username.text.trim(),
      authenticationMode: _authenticationMode,
      privateKeyPath: _privateKey.text.trim(),
      savePassword:
          _authenticationMode == SshAuthenticationMode.password &&
          _savePassword,
      keepAliveEnabled: AppSettings().sshKeepAliveEnabled,
    );
  }

  void _scheduleConfigSave() {
    _configSaveTimer?.cancel();
    _configSaveTimer = Timer(const Duration(milliseconds: 300), () {
      final config = _buildConfig();
      if (config != null) unawaited(_queueConfigSave(config));
    });
  }

  Future<void> _persistConfig(SshConnectionConfig config) async {
    final previous = _lastValidConfig;
    final identityChanged =
        previous.endpointKey != config.endpointKey ||
        previous.username.trim().toLowerCase() !=
            config.username.trim().toLowerCase();
    final settings = AppSettings()..sshConnectionConfig = config;
    await settings.save();
    if (previous.savePassword && (identityChanged || !config.savePassword)) {
      widget.passwordStore.delete(previous);
    }
    _lastValidConfig = config;
  }

  Future<void> _queueConfigSave(SshConnectionConfig config) {
    _pendingConfigSave = _pendingConfigSave.then(
      (_) => _persistConfig(config),
      onError: (_) => _persistConfig(config),
    );
    return _pendingConfigSave;
  }

  Future<SshConnectionConfig?> _flushConfigSave({bool showError = true}) async {
    _configSaveTimer?.cancel();
    final config = _buildConfig();
    if (config == null) {
      if (showError && mounted) {
        setState(() => _error = '请填写有效的主机、端口、用户名和认证参数');
      }
      return null;
    }
    try {
      await _queueConfigSave(config);
      return config;
    } catch (error) {
      if (mounted) setState(() => _error = '保存 SSH 配置失败：$error');
      return null;
    }
  }

  Future<void> _connect() async {
    final config = await _flushConfigSave();
    if (config == null) return;
    if (config.savePassword && _password.text.isEmpty) {
      setState(() => _error = '密码为空，无法保存密码');
      return;
    }
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
      if (config.savePassword) {
        widget.passwordStore.write(config, _password.text);
      }
      if (mounted && service.isConnected) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    await _flushConfigSave(showError: false);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _disconnect() async {
    final service = context.read<SshConnectionService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.disconnect();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = 'SSH 断开失败：$error');
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
    final locked =
        _busy ||
        service.isConnecting ||
        service.isConnected ||
        service.isDisconnecting;
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
              AppDialogDropdown<SshAuthenticationMode>(
                value: _authenticationMode,
                hint: '认证方式',
                labelText: '认证方式',
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
                            _scheduleConfigSave();
                          }
                        },
              ),
              const SizedBox(height: 12),
              if (_authenticationMode == SshAuthenticationMode.password)
                AppDialogTextField(
                  controller: _password,
                  enabled: !locked,
                  obscureText: _obscurePassword,
                  labelText: '密码',
                  suffixIcon: IconButton(
                    splashRadius: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
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
              if (_authenticationMode == SshAuthenticationMode.password) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _savePassword,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged:
                            locked
                                ? null
                                : (value) {
                                  setState(
                                    () => _savePassword = value ?? false,
                                  );
                                  _scheduleConfigSave();
                                },
                      ),
                      const SizedBox(width: 4),
                      const Text('保存密码（使用 Windows 凭据管理器）'),
                    ],
                  ),
                ),
              ] else ...[
                AppDialogTextField(
                  controller: _privateKey,
                  enabled: !locked,
                  labelText: 'PEM 私钥文件',
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
                const SizedBox(height: 12),
                AppDialogTextField(
                  controller: _passphrase,
                  enabled: !locked,
                  obscureText: true,
                  labelText: '私钥口令（可选，不会保存）',
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
          onPressed: _busy ? null : () => unawaited(_close()),
          child: const Text('关闭'),
        ),
        if (service.isConnected || service.isDisconnecting)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: _busy ? null : () => unawaited(_disconnect()),
            icon:
                _busy
                    ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.link_off),
            label: Text(_busy ? '断开中' : '断开'),
          )
        else
          ElevatedButton.icon(
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
  }) => AppLabeledField(
    label: label,
    child: TextField(
      controller: controller,
      enabled: enabled,
      decoration: const InputDecoration(border: OutlineInputBorder()),
    ),
  );
}
