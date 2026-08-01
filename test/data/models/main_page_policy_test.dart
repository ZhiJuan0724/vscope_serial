import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_connection_config.dart';
import 'package:vscope_serial/data/models/main_page_policy.dart';

void main() {
  test('页面添加不重复且关闭时至少保留一个页面', () {
    expect(MainPagePolicy.addPage(['rawData'], 'plot'), ['rawData', 'plot']);
    expect(MainPagePolicy.addPage(['rawData'], 'rawData'), ['rawData']);
    expect(
      MainPagePolicy.closePage(['rawData'], 'rawData', connectionBusy: false),
      ['rawData'],
    );
  });

  test('重新添加的页面移到用户顺序末尾', () {
    expect(
      MainPagePolicy.appendPageOrder([
        'rawData',
        'shell',
        'plot',
        'rtt',
        'probePlot',
      ], 'shell'),
      ['rawData', 'plot', 'rtt', 'probePlot', 'shell'],
    );
  });

  test('连接期间拒绝关闭页面', () {
    expect(
      MainPagePolicy.closePage(
        ['rawData', 'plot'],
        'plot',
        connectionBusy: true,
      ),
      ['rawData', 'plot'],
    );
  });

  test('连接类型只允许进入兼容页面', () {
    expect(
      MainPagePolicy.supportsDataConnection('shell', DataConnectionType.serial),
      isTrue,
    );
    expect(
      MainPagePolicy.supportsDataConnection(
        'shell',
        DataConnectionType.tcpClient,
      ),
      isTrue,
    );
    expect(
      MainPagePolicy.supportsDataConnection('plot', DataConnectionType.udp),
      isTrue,
    );
    expect(
      MainPagePolicy.supportsDataConnection(
        'plot',
        DataConnectionType.tcpServer,
      ),
      isFalse,
    );
  });
}
