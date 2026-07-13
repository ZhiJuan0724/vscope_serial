class MathExpression {
  final _ExprNode _root;
  final int futureLookahead;
  final bool hasChannelOffset;

  const MathExpression._(
    this._root, {
    required this.futureLookahead,
    required this.hasChannelOffset,
  });

  static MathExpression parse(String source) {
    final parser = _MathExpressionParser(source);
    final root = parser.parse();
    return MathExpression._(
      root,
      futureLookahead: root.futureLookahead,
      hasChannelOffset: root.hasChannelOffset,
    );
  }

  double evaluate(List<double> channels) {
    final value = evaluateWithContext(MathEvalContext.single(channels));
    return value.isFinite ? value : double.nan;
  }

  double evaluateWithContext(MathEvalContext context) {
    final value = _root.evaluate(context);
    return value.isFinite ? value : double.nan;
  }
}

class MathEvalContext {
  final int currentIndex;
  final int pointCount;
  final double Function(int pointIndex, int channelIndex) valueAt;

  const MathEvalContext({
    required this.currentIndex,
    required this.pointCount,
    required this.valueAt,
  });

  factory MathEvalContext.single(List<double> channels) {
    return MathEvalContext(
      currentIndex: 0,
      pointCount: 1,
      valueAt: (pointIndex, channelIndex) {
        if (pointIndex != 0 ||
            channelIndex < 0 ||
            channelIndex >= channels.length) {
          return double.nan;
        }
        return channels[channelIndex];
      },
    );
  }
}

abstract class _ExprNode {
  const _ExprNode();

  int get futureLookahead => 0;

  bool get hasChannelOffset => false;

  double evaluate(MathEvalContext context);
}

class _NumberNode extends _ExprNode {
  final double value;

  const _NumberNode(this.value);

  @override
  double evaluate(MathEvalContext context) => value;
}

class _ChannelNode extends _ExprNode {
  final int index;
  final int xOffset;

  const _ChannelNode(this.index, {this.xOffset = 0});

  @override
  int get futureLookahead => xOffset < 0 ? -xOffset : 0;

  @override
  bool get hasChannelOffset => xOffset != 0;

  @override
  double evaluate(MathEvalContext context) {
    final sourceIndex = context.currentIndex - xOffset;
    if (sourceIndex < 0 || sourceIndex >= context.pointCount) {
      return double.nan;
    }
    return context.valueAt(sourceIndex, index);
  }
}

class _UnaryNode extends _ExprNode {
  final String op;
  final _ExprNode child;

  const _UnaryNode(this.op, this.child);

  @override
  int get futureLookahead => child.futureLookahead;

  @override
  bool get hasChannelOffset => child.hasChannelOffset;

  @override
  double evaluate(MathEvalContext context) {
    final value = child.evaluate(context);
    return switch (op) {
      '-' => -value,
      'abs' => value.isNaN ? double.nan : value.abs(),
      _ => double.nan,
    };
  }
}

class _BinaryNode extends _ExprNode {
  final String op;
  final _ExprNode left;
  final _ExprNode right;

  const _BinaryNode(this.op, this.left, this.right);

  @override
  int get futureLookahead =>
      left.futureLookahead > right.futureLookahead
          ? left.futureLookahead
          : right.futureLookahead;

  @override
  bool get hasChannelOffset => left.hasChannelOffset || right.hasChannelOffset;

  @override
  double evaluate(MathEvalContext context) {
    final a = left.evaluate(context);
    final b = right.evaluate(context);
    if (!a.isFinite || !b.isFinite) return double.nan;
    return switch (op) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      '/' => b == 0 ? double.nan : a / b,
      _ => double.nan,
    };
  }
}

class _MathExpressionParser {
  final String source;
  int _offset = 0;

  _MathExpressionParser(this.source);

  _ExprNode parse() {
    final expr = _parseExpression();
    _skipSpaces();
    if (!_isEnd) {
      throw FormatException('表达式包含无法解析的内容', source, _offset);
    }
    return expr;
  }

  _ExprNode _parseExpression() {
    var node = _parseTerm();
    while (true) {
      _skipSpaces();
      if (_consume('+')) {
        node = _BinaryNode('+', node, _parseTerm());
      } else if (_consume('-')) {
        node = _BinaryNode('-', node, _parseTerm());
      } else {
        return node;
      }
    }
  }

  _ExprNode _parseTerm() {
    var node = _parseFactor();
    while (true) {
      _skipSpaces();
      if (_consume('*')) {
        node = _BinaryNode('*', node, _parseFactor());
      } else if (_consume('/')) {
        node = _BinaryNode('/', node, _parseFactor());
      } else {
        return node;
      }
    }
  }

  _ExprNode _parseFactor() {
    _skipSpaces();
    if (_consume('-')) return _UnaryNode('-', _parseFactor());
    if (_consume('+')) return _parseFactor();
    if (_consume('(')) {
      final node = _parseExpression();
      _skipSpaces();
      if (!_consume(')')) {
        throw FormatException('缺少右括号', source, _offset);
      }
      return node;
    }
    if (_matchIdentifier('abs')) {
      _offset += 3;
      _skipSpaces();
      if (!_consume('(')) {
        throw FormatException('abs 后缺少左括号', source, _offset);
      }
      final node = _parseExpression();
      _skipSpaces();
      if (!_consume(')')) {
        throw FormatException('abs 缺少右括号', source, _offset);
      }
      return _UnaryNode('abs', node);
    }
    if (_matchIdentifier('ch')) {
      _offset += 2;
      final start = _offset;
      while (!_isEnd && _isDigit(source.codeUnitAt(_offset))) {
        _offset++;
      }
      if (start == _offset) {
        throw FormatException('CH 后缺少通道索引', source, _offset);
      }
      final index = int.parse(source.substring(start, _offset));
      if (index < 0 || index > 15) {
        throw FormatException('通道索引超出范围 CH0~CH15', source, start);
      }
      final xOffset = _parseOptionalChannelOffset();
      return _ChannelNode(index, xOffset: xOffset);
    }
    return _parseNumber();
  }

  int _parseOptionalChannelOffset() {
    _skipSpaces();
    if (!_consume('[')) return 0;
    _skipSpaces();
    var sign = 1;
    if (_consume('-')) {
      sign = -1;
    } else {
      _consume('+');
    }
    final start = _offset;
    while (!_isEnd && _isDigit(source.codeUnitAt(_offset))) {
      _offset++;
    }
    if (start == _offset) {
      throw FormatException('CH 偏移缺少整数', source, _offset);
    }
    final value = int.parse(source.substring(start, _offset)) * sign;
    _skipSpaces();
    if (!_consume(']')) {
      throw FormatException('CH 偏移缺少右中括号', source, _offset);
    }
    return value;
  }

  _ExprNode _parseNumber() {
    _skipSpaces();
    final start = _offset;
    var hasDot = false;
    while (!_isEnd) {
      final code = source.codeUnitAt(_offset);
      if (_isDigit(code)) {
        _offset++;
      } else if (code == 46 && !hasDot) {
        hasDot = true;
        _offset++;
      } else {
        break;
      }
    }
    if (start == _offset) {
      throw FormatException('需要数字、CHn 或函数', source, _offset);
    }
    final value = double.tryParse(source.substring(start, _offset));
    if (value == null || value.isNaN || value.isInfinite) {
      throw FormatException('数字格式错误', source, start);
    }
    return _NumberNode(value);
  }

  bool _consume(String text) {
    if (!source.startsWith(text, _offset)) return false;
    _offset += text.length;
    return true;
  }

  bool _matchIdentifier(String text) {
    if (_offset + text.length > source.length) return false;
    return source.substring(_offset, _offset + text.length).toLowerCase() ==
        text;
  }

  void _skipSpaces() {
    while (!_isEnd && source.codeUnitAt(_offset) <= 32) {
      _offset++;
    }
  }

  bool get _isEnd => _offset >= source.length;

  bool _isDigit(int code) => code >= 48 && code <= 57;
}
