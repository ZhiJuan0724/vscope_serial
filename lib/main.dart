import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/constants/window_configuration.dart';
import 'core/localization/app_strings.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/app_logger.dart';
import 'services/app_notifications.dart';
import 'services/app_info.dart';
import 'services/app_settings.dart';
import 'services/connection_owner_service.dart';
import 'services/rtt_service.dart';
import 'services/serial_service.dart';
import 'services/update_checker.dart';
import 'services/update_service.dart';
import 'views/dialogs/app_info_dialog.dart';
import 'viewmodels/plot_viewmodel.dart';
import 'viewmodels/rtt_viewmodel.dart';
import 'viewmodels/shell_viewmodel.dart';
import 'views/pages/plot_page.dart';
import 'views/pages/raw_data_page.dart';
import 'views/pages/rtt_page.dart';
import 'views/pages/shell_page.dart';
import 'views/widgets/app_icon.dart';
import 'views/widgets/status_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Provider.debugCheckInvalidValueType = null;
  await AppLogger().init();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLogger().error(
      'Flutter 框架异常: ${details.exceptionAsString()}',
      category: 'APP',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLogger().error(
      'Flutter 平台异常: $error',
      category: 'APP',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  };
  await AppSettings().init();
  SerialService().loadSettings();
  SerialService().initializePortDiscovery();
  await AppIcon.precacheAll();

  // 初始化窗口管理
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(
      WindowConfiguration.defaultWidth,
      WindowConfiguration.defaultHeight,
    ),
    minimumSize: const Size(
      WindowConfiguration.minWidth,
      WindowConfiguration.minHeight,
    ),
    center: true,
    title: AppStrings.appName,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  Widget app = const MyApp();
  if (Platform.isWindows) {
    // 临时规避 Flutter Windows Tooltip 触发的 AXTree 更新错误日志洪泛。
    app = ExcludeSemantics(child: app);
  }
  runApp(app);
}

/// 应用根节点，统一注入全局服务、主题和 Windows 语义兼容配置。
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // SerialService 是全局单例，使用 Provider.value 避免 Provider
    // 在重建时 dispose 单例导致连接被意外断开。
    final serialService = SerialService();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ConnectionOwnerService()),
        ChangeNotifierProvider.value(value: serialService),
        ChangeNotifierProvider(
          create: (_) {
            final service = RttService();
            unawaited(service.initialize());
            return service;
          },
        ),
        ChangeNotifierProvider(
          create: (context) => PlotViewModel(serialService),
        ),
        ChangeNotifierProvider(
          create: (context) => ShellViewModel(serialService),
        ),
        ChangeNotifierProvider(
          create: (context) => RttViewModel(context.read<RttService>()),
        ),
      ],
      child: MaterialApp(
        title: AppStrings.appName,
        scaffoldMessengerKey: AppNotifications.scaffoldMessengerKey,
        theme: AppTheme.buildLightTheme(),
        home: const MainFrame(),
      ),
    );
  }
}

/// 主页面标签容器，负责恢复上次页面并遵守串口与 RTT 活动锁。
class MainFrame extends StatefulWidget {
  const MainFrame({super.key});

  @override
  State<MainFrame> createState() => _MainFrameState();
}

class _MainFrameState extends State<MainFrame> with WidgetsBindingObserver {
  String _currentTabId = 'rawData';
  _WindowCloseListener? _windowCloseListener;

  @override
  void initState() {
    super.initState();
    final savedPage = AppSettings().lastMainPage;
    final settings = AppSettings();
    _currentTabId = switch (savedPage) {
      'shell' when !settings.rawDataShellEnabled => 'rawData',
      'rtt' when !settings.rttPageEnabled => 'rawData',
      _ => savedPage,
    };
    WidgetsBinding.instance.addObserver(this);
    // 注册窗口关闭处理：关闭前先断开串口。
    _setupWindowCloseHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final recoveryNotice = AppSettings().takeRecoveryNotice();
      if (recoveryNotice != null) AppNotifications.show(recoveryNotice);
      unawaited(_handleStartupUpdates());
    });
  }

  Future<void> _handleStartupUpdates() async {
    final service = UpdateService();
    final channel = UpdateChannel.fromString(AppSettings().updateChannel);
    final sourcePreference = UpdateSourcePreference.fromString(
      AppSettings().updateSource,
    );
    final message = await service.consumeLastResult();
    if (message != null && mounted) AppNotifications.show(message);
    final prepared = await service.findLatestPreparedUpdate(
      newerThanVersion: await AppInfo.version(),
      channel: channel,
    );
    if (prepared != null && mounted) {
      await showUpdateAvailableDialog(
        context,
        prepared.release,
        sourcePreference: sourcePreference,
      );
    } else if (AppSettings().autoUpdateCheckEnabled) {
      await _checkForUpdatesOnStartup();
    }
    await service.cleanupOldUpdates();
  }

  void _setupWindowCloseHandler() {
    windowManager.setPreventClose(true);
    final listener = _WindowCloseListener(context);
    _windowCloseListener = listener;
    windowManager.addListener(listener);
  }

  Future<void> _checkForUpdatesOnStartup() async {
    final result = await UpdateChecker().check(
      channel: UpdateChannel.fromString(AppSettings().updateChannel),
      source:
          UpdateSourcePreference.fromString(
            AppSettings().updateSource,
          ).releaseSource,
    );
    if (!mounted) return;
    if (result.hasUpdate && result.latestRelease != null) {
      await showUpdateAvailableDialog(
        context,
        result.latestRelease!,
        sourcePreference: UpdateSourcePreference.fromString(
          AppSettings().updateSource,
        ),
      );
    } else if (result.error != null) {
      AppLogger().warning('自动检查更新失败: ${result.error}', category: 'UPDATE');
    }
  }

  @override
  void dispose() {
    final listener = _windowCloseListener;
    if (listener != null) windowManager.removeListener(listener);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      AppLogger().disposeLogger();
    }
  }

  List<({String id, String label, IconData icon, Widget page})> get _tabs => [
    (
      id: 'rawData',
      label: AppStrings.nav.rawData,
      icon: Icons.data_object,
      page: const RawDataPage(),
    ),
    if (AppSettings().rawDataShellEnabled)
      (
        id: 'shell',
        label: AppStrings.nav.shell,
        icon: Icons.terminal,
        page: const ShellPage(),
      ),
    (
      id: 'plot',
      label: AppStrings.nav.plot,
      icon: Icons.show_chart,
      page: const PlotPage(),
    ),
    if (AppSettings().rttPageEnabled)
      (
        id: 'rtt',
        label: AppStrings.nav.rtt,
        icon: Icons.developer_board,
        page: const RttPage(),
      ),
  ];

  void _selectTab(String id) {
    if (id == _currentTabId) return;
    setState(() {
      _currentTabId = id;
    });
    final settings = AppSettings();
    settings.lastMainPage = id;
    unawaited(settings.save());
  }

  @override
  Widget build(BuildContext context) {
    final serialService = Provider.of<SerialService>(context);
    final connectionOwner = Provider.of<ConnectionOwnerService>(context);
    // RTT 页面显隐由 RttService 通知，监听它以即时刷新标签列表。
    Provider.of<RttService>(context);
    final tabs = _tabs;
    if (!tabs.any((tab) => tab.id == _currentTabId)) {
      _currentTabId = 'rawData';
    }
    final currentIndex = tabs.indexWhere((tab) => tab.id == _currentTabId);

    return Scaffold(
      body: Column(
        children: [
          // 顶部 Tab 切换栏
          Container(
            height: 40,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children:
                      tabs.asMap().entries.map((entry) {
                        final index = entry.key;
                        final tab = entry.value;
                        final isSelected = index == currentIndex;
                        final ownerTab = switch (serialService.activityOwner) {
                          SerialActivityOwner.rawData => 'rawData',
                          SerialActivityOwner.shell => 'shell',
                          SerialActivityOwner.plot => 'plot',
                          SerialActivityOwner.none => null,
                        };
                        final canSwitch =
                            connectionOwner.owner == ConnectionOwner.rtt
                                ? tab.id == 'rtt'
                                : ownerTab == null || tab.id == ownerTab;
                        final colorScheme = Theme.of(context).colorScheme;
                        final foreground =
                            isSelected
                                ? colorScheme.primary
                                : canSwitch
                                ? colorScheme.onSurfaceVariant
                                : colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.3,
                                );
                        const tabRadius = BorderRadius.vertical(
                          top: Radius.circular(7),
                        );
                        return SizedBox(
                          width: 180,
                          height: 35,
                          child: Material(
                            color:
                                isSelected
                                    ? Theme.of(context).scaffoldBackgroundColor
                                    : Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            borderRadius: tabRadius,
                            child: InkWell(
                              borderRadius: tabRadius,
                              onTap:
                                  canSwitch ? () => _selectTab(tab.id) : null,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(tab.icon, size: 16, color: foreground),
                                  const SizedBox(width: 6),
                                  Text(
                                    tab.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight:
                                          isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                      color: foreground,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                ),
              ),
            ),
          ),
          // 页面内容
          Expanded(
            child: IndexedStack(
              index: currentIndex,
              children: tabs.map((tab) => tab.page).toList(),
            ),
          ),
          // 底部共享状态栏
          StatusBar(currentPageId: _currentTabId),
        ],
      ),
    );
  }
}

/// 窗口关闭监听器：允许窗口关闭前先断开串口。
class _WindowCloseListener extends WindowListener {
  final BuildContext context;
  bool _isClosing = false;

  _WindowCloseListener(this.context);

  @override
  void onWindowClose() async {
    if (_isClosing) return;
    _isClosing = true;
    final serialService = Provider.of<SerialService>(context, listen: false);
    final rttService = Provider.of<RttService>(context, listen: false);
    await AppSettings().flushPendingSave();
    await rttService.disconnect();
    await serialService.shutdown();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}
