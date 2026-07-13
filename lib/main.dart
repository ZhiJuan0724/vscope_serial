import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/localization/app_strings.dart';
import 'core/utils/app_logger.dart';
import 'services/app_notifications.dart';
import 'services/app_info.dart';
import 'services/app_settings.dart';
import 'services/serial_service.dart';
import 'services/update_checker.dart';
import 'services/update_service.dart';
import 'views/dialogs/app_info_dialog.dart';
import 'viewmodels/plot_viewmodel.dart';
import 'views/pages/plot_page.dart';
import 'views/pages/raw_data_page.dart';
import 'views/widgets/app_icon.dart';
import 'views/widgets/status_bar.dart';

/// 主窗口最小宽度：保证左侧控件 + 一个下拉菜单按钮能放下
const double kMinWindowWidth = 650;

/// 主窗口默认宽度
const double kDefaultWindowWidth = 1000;

/// 主窗口默认高度
const double kDefaultWindowHeight = 700;

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
    size: const Size(kDefaultWindowWidth, kDefaultWindowHeight),
    minimumSize: const Size(kMinWindowWidth, 600),
    center: true,
    title: AppStrings.appName,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // SerialService 是全局单例，使用 Provider.value 避免 Provider
    // 在重建时 dispose 单例导致连接被意外断开。
    final serialService = SerialService();
    final baseTheme = ThemeData(
      useMaterial3: false,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    );
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: serialService),
        ChangeNotifierProvider(
          create: (context) => PlotViewModel(serialService),
        ),
      ],
      child: MaterialApp(
        title: AppStrings.appName,
        scaffoldMessengerKey: AppNotifications.scaffoldMessengerKey,
        theme: baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'SarasaUiSC'),
          primaryTextTheme: baseTheme.primaryTextTheme.apply(
            fontFamily: 'SarasaUiSC',
          ),
        ),
        home: const MainFrame(),
      ),
    );
  }
}

class MainFrame extends StatefulWidget {
  const MainFrame({super.key});

  @override
  State<MainFrame> createState() => _MainFrameState();
}

class _MainFrameState extends State<MainFrame> with WidgetsBindingObserver {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    final savedPage = AppSettings().lastMainPage;
    final savedIndex = _tabs.indexWhere((tab) => tab.id == savedPage);
    _currentIndex = savedIndex < 0 ? 0 : savedIndex;
    WidgetsBinding.instance.addObserver(this);
    // 注册窗口关闭处理：关闭前先断开串口。
    _setupWindowCloseHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    windowManager.addListener(_WindowCloseListener(context));
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      AppLogger().disposeLogger();
    }
  }

  final List<({String id, String label, IconData icon, Widget page})> _tabs = [
    (
      id: 'rawData',
      label: AppStrings.nav.rawData,
      icon: Icons.terminal,
      page: const RawDataPage(),
    ),
    (
      id: 'plot',
      label: AppStrings.nav.plot,
      icon: Icons.show_chart,
      page: const PlotPage(),
    ),
  ];

  void _selectTab(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
    });
    final settings = AppSettings();
    settings.lastMainPage = _tabs[index].id;
    unawaited(settings.save());
  }

  @override
  Widget build(BuildContext context) {
    final serialService = Provider.of<SerialService>(context);
    final isPlotting = serialService.isPlotting;

    return Scaffold(
      body: Column(
        children: [
          // 顶部 Tab 切换栏
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children:
                      _tabs.asMap().entries.map((entry) {
                        final index = entry.key;
                        final tab = entry.value;
                        final isSelected = index == _currentIndex;
                        final canSwitch = !isPlotting || tab.id == 'plot';
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
                                    ? colorScheme.surface
                                    : Colors.transparent,
                            borderRadius: tabRadius,
                            child: InkWell(
                              borderRadius: tabRadius,
                              onTap: canSwitch ? () => _selectTab(index) : null,
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
          Expanded(child: _tabs[_currentIndex].page),
          // 底部共享状态栏
          const StatusBar(),
        ],
      ),
    );
  }
}

/// 窗口关闭监听器：允许窗口关闭前先断开串口。
class _WindowCloseListener extends WindowListener {
  final BuildContext context;

  _WindowCloseListener(this.context);

  @override
  void onWindowClose() async {
    final serialService = Provider.of<SerialService>(context, listen: false);
    if (serialService.isConnected) {
      serialService.disconnect();
      // 等待断开完成（C++ 线程 join 和资源清理）。
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}
