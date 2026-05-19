import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/utils/app_logger.dart';
import 'services/app_settings.dart';
import 'services/serial_service.dart';
import 'views/pages/connect_page.dart';
import 'views/pages/plot_page.dart';
import 'views/pages/protocol_page.dart';
import 'views/pages/raw_data_page.dart';
import 'views/widgets/status_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Provider.debugCheckInvalidValueType = null;
  await AppLogger().init();
  await AppSettings().init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SerialService()),
      ],
      child: MaterialApp(
        title: 'VScope Serial',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // 应用退出时关闭日志文件
      AppLogger().disposeLogger();
    }
  }

  final List<({String label, IconData icon, Widget page})> _tabs = [
    (label: '连接', icon: Icons.cable, page: const ConnectPage()),
    (label: '原始数据', icon: Icons.terminal, page: const RawDataPage()),
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
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
            child: Row(
              children: _tabs.asMap().entries.map((entry) {
                final index = entry.key;
                final tab = entry.value;
                final isSelected = index == _currentIndex;
                // 绘图开启时禁止切换页面：非绘图页 Tab 置灰且不可点击
                final isPlotTab = index == 2;
                final canSwitch = !isPlotting || isPlotTab;
                return Expanded(
                  child: InkWell(
                    onTap: canSwitch
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
                            color: isSelected
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
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : canSwitch
                                    ? Theme.of(context).colorScheme.onSurfaceVariant
                                    : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            tab.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : canSwitch
                                      ? Theme.of(context).colorScheme.onSurfaceVariant
                                      : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
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
          Expanded(
            child: _tabs[_currentIndex].page,
          ),
          // 底部共享状态栏
          const StatusBar(),
        ],
      ),
    );
  }
}
