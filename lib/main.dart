import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/utils/app_logger.dart';
import 'services/app_notifications.dart';
import 'services/app_settings.dart';
import 'services/serial_service.dart';
import 'viewmodels/plot_viewmodel.dart';
import 'views/pages/plot_page.dart';
import 'views/pages/protocol_page.dart';
import 'views/pages/raw_data_page.dart';
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
  await AppSettings().init();

  // 初始化窗口管理
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(kDefaultWindowWidth, kDefaultWindowHeight),
    minimumSize: const Size(kMinWindowWidth, 600),
    center: true,
    title: 'VScope Serial',
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
        title: 'VScope Serial',
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
    WidgetsBinding.instance.addObserver(this);
    // Register window close handler: disconnect serial before closing
    _setupWindowCloseHandler();
  }

  void _setupWindowCloseHandler() {
    windowManager.setPreventClose(true);
    windowManager.addListener(_WindowCloseListener(context));
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

  final List<({String label, IconData icon, Widget page})> _tabs = [
    (label: '数据收发', icon: Icons.terminal, page: const RawDataPage()),
    (label: '绘图', icon: Icons.show_chart, page: const PlotPage()),
    (label: '协议', icon: Icons.settings_ethernet, page: const ProtocolPage()),
  ];

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
            child: Row(
              children:
                  _tabs.asMap().entries.map((entry) {
                    final index = entry.key;
                    final tab = entry.value;
                    final isSelected = index == _currentIndex;
                    // 绘图开启时禁止切换页面：非绘图页 Tab 置灰且不可点击
                    final isPlotTab = tab.label == '绘图';
                    final canSwitch = !isPlotting || isPlotTab;
                    return Expanded(
                      child: InkWell(
                        onTap:
                            canSwitch
                                ? () {
                                  setState(() {
                                    _currentIndex = index;
                                  });
                                }
                                : null,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color:
                                    isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                tab.icon,
                                size: 16,
                                color:
                                    isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : canSwitch
                                        ? Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant
                                        : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant
                                            .withValues(alpha: 0.3),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                tab.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight:
                                      isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                  color:
                                      isSelected
                                          ? Theme.of(
                                            context,
                                          ).colorScheme.primary
                                          : canSwitch
                                          ? Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                              .withValues(alpha: 0.3),
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
          // 页面内容
          Expanded(child: _tabs[_currentIndex].page),
          // 底部共享状态栏
          const StatusBar(),
        ],
      ),
    );
  }
}

/// Window close listener: disconnect serial before allowing window to close
class _WindowCloseListener extends WindowListener {
  final BuildContext context;

  _WindowCloseListener(this.context);

  @override
  void onWindowClose() async {
    final serialService = Provider.of<SerialService>(context, listen: false);
    if (serialService.isConnected) {
      serialService.disconnect();
      // Wait for disconnect to complete (C++ thread join + cleanup)
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}
