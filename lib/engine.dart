import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// تنظيف النص العربي للمقارنة (تشكيل، همزات، تاء مربوطة، "ال" التعريف...)
String normalize(String s) {
  var t = s.trim().toLowerCase();
  t = t.replaceAll(RegExp(r'[ً-ٰٟـ]'), '');
  t = t.replaceAll(RegExp('[أإآٱ]'), 'ا');
  t = t.replaceAll('ة', 'ه').replaceAll('ى', 'ي');
  t = t.replaceAll('ؤ', 'و').replaceAll('ئ', 'ي');
  t = t.replaceAll(RegExp(r'[^؀-ۿa-z0-9\s]'), ' ');
  t = t.replaceAllMapped(RegExp(r'(^|\s)ال(?=\S{2,})'), (m) => m.group(1)!);
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t;
}

class _Cat {
  final String title;
  final String asset;
  final String intro;
  const _Cat(this.title, this.asset, this.intro);
}

class _Quiz {
  final String key;
  Map<String, String> current;
  _Quiz(this.key, this.current);
}

class Engine {
  final Random _rnd = Random();
  final Map<String, List<Map<String, String>>> _data = {};
  final Map<String, String> _lastAsked = {};
  int points = 0;

  _Quiz? _quiz;
  List<String>? _xo; // 9 خانات: '' / 'X' / 'O'
  int? _secret;
  int _tries = 0;

  static const Map<String, _Cat> _cats = {
    'kt': _Cat('كت', 'assets/data/kt.json', '🧠 سؤال عام'),
    'cap': _Cat('عواصم', 'assets/data/cap.json', '🌍 عواصم'),
    'his': _Cat('تاريخ', 'assets/data/his.json', '📜 تاريخ'),
    'fk': _Cat('فكك', 'assets/data/fk.json', '🔤 فكك الحروف ورتّبها'),
    'mi': _Cat('ايموجي', 'assets/data/mi.json', '😀 وش يعني الايموجي؟'),
    'anime': _Cat('انمي', 'assets/data/anime.json', '🎌 أسئلة أنمي'),
    'char': _Cat('احزر', 'assets/data/char.json', '🎯 احزر الشخصية'),
  };

  // أمر -> مفتاح القسم (بعد التنظيف)
  late final Map<String, String> _quizCmds = {
    for (final e in {
      'كت': 'kt',
      'عواصم': 'cap',
      'عاصمه': 'cap',
      'عاصمة': 'cap',
      'تاريخ': 'his',
      'فكك': 'fk',
      'ايموجي': 'mi',
      'اميوجي': 'mi',
      'انمي': 'anime',
      'سؤال': 'anime',
      'احزر': 'char',
    }.entries)
      normalize(e.key): e.value
  };

  static const _numEmoji = ['1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣'];
  static const _lines = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6],
  ];

  Future<void> init() async {
    for (final e in _cats.entries) {
      try {
        final raw = await rootBundle.loadString(e.value.asset);
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _data[e.key] = list.map<Map<String, String>>((m) {
          if (e.key == 'char') {
            return {
              'q': 'تلميح: ${m['hint']}',
              'a': '${m['name']}',
            };
          }
          return {'q': '${m['question']}', 'a': '${m['response']}'};
        }).toList();
      } catch (_) {
        _data[e.key] = [];
      }
    }
    try {
      final p = await SharedPreferences.getInstance();
      points = p.getInt('points') ?? 0;
    } catch (_) {}
  }

  Future<void> _savePoints() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('points', points);
    } catch (_) {}
  }

  String menu() => '''
╭─── AKATSU ───╮
🎮 ألعاب الأسئلة:
• كت  • عواصم  • تاريخ
• فكك  • ايموجي  • انمي  • احزر
(أثناء اللعبة: تلميح / تخطي / ايقاف)

🕹️ ألعاب ثانية:
• اكس_او  (العب ضد الجهاز)
• تخمين  (خمّن رقم من 1 إلى 100)
• حجر / ورقة / مقص

🎲 أدوات:
• نرد  • عملة  • رقم  • وقت
• نقاطي  • تصفير

اكتب الأمر وارسله 👇
╰────────────╯''';

  Future<String> handle(String raw) async {
    var text = raw.trim();
    if (text.isEmpty) return '';
    text = text.replaceFirst(RegExp(r'^[./!#]+'), '').trim();
    final norm = normalize(text);
    final cmd = norm.split(' ').first;

    // ===== أوامر عامة =====
    if (const ['اوامر', 'القائمه', 'قائمه', 'menu', 'help', 'مساعده'].contains(cmd)) {
      return menu();
    }
    if (cmd == 'ايقاف' || cmd == 'وقف' || cmd == 'انهاء') {
      if (_quiz == null && _xo == null && _secret == null) return 'ما فيه لعبة شغالة.';
      _quiz = null;
      _xo = null;
      _secret = null;
      return '🛑 تم إيقاف اللعبة.';
    }
    if (cmd == 'نقاطي' || cmd == 'نقاط') return '⭐ نقاطك: $points';
    if (cmd == 'تصفير') {
      points = 0;
      await _savePoints();
      return '♻️ تم تصفير النقاط.';
    }

    // ===== بدء ألعاب الأسئلة =====
    if (_quizCmds.containsKey(cmd)) {
      _xo = null;
      _secret = null;
      return _nextQuestion(_quizCmds[cmd]!);
    }

    // ===== اكس او =====
    if (cmd == 'اكس_او' || norm == 'اكس او' || cmd == 'xo' || cmd == 'اكسو') {
      _quiz = null;
      _secret = null;
      _xo = List.filled(9, '');
      return '❌⭕ لعبة إكس أو\nأنت ❌ وأنا ⭕\nاختر رقم الخانة (1-9):\n\n${_renderXo()}';
    }

    // ===== تخمين رقم =====
    if (cmd == 'تخمين') {
      _quiz = null;
      _xo = null;
      _secret = _rnd.nextInt(100) + 1;
      _tries = 0;
      return '🔢 خمّنت رقم بين 1 و 100. اكتب تخمينك!';
    }

    // ===== جلسات شغالة =====
    final numMatch = RegExp(r'^\d{1,3}$').firstMatch(norm);
    if (_xo != null && numMatch != null) {
      return _xoMove(int.parse(numMatch.group(0)!));
    }
    if (_secret != null && numMatch != null) {
      return _guess(int.parse(numMatch.group(0)!));
    }

    if (_quiz != null) {
      if (cmd == 'تلميح') return _hint();
      if (cmd == 'تخطي') {
        final a = _quiz!.current['a']!;
        return '⏭️ الإجابة كانت: $a\n\n${_nextQuestion(_quiz!.key)}';
      }
      return _checkAnswer(norm);
    }

    // ===== أوامر فورية =====
    switch (cmd) {
      case 'نرد':
        return '🎲 طلع لك: ${_rnd.nextInt(6) + 1}';
      case 'عمله':
      case 'عملة':
        return _rnd.nextBool() ? '🪙 صورة' : '🪙 كتابة';
      case 'رقم':
        final n = RegExp(r'\d+').allMatches(norm).map((m) => int.parse(m.group(0)!)).toList();
        final top = n.isNotEmpty ? n.first : 100;
        return '🔢 ${_rnd.nextInt(top < 1 ? 1 : top) + 1}';
      case 'وقت':
        final d = DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        return '🕒 ${two(d.hour)}:${two(d.minute)}:${two(d.second)}\n📅 ${d.year}-${two(d.month)}-${two(d.day)}';
      case 'حجر':
      case 'ورقه':
      case 'مقص':
        return _rps(cmd);
      case 'تلميح':
      case 'تخطي':
        return 'ما فيه لعبة شغالة. اكتب "اوامر" لعرض القائمة.';
    }

    return 'ما عرفت الأمر 🤔\nاكتب "اوامر" لعرض القائمة.';
  }

  // ---------------- الأسئلة ----------------
  String _nextQuestion(String key) {
    final list = _data[key] ?? [];
    if (list.isEmpty) return '⚠️ ما فيه أسئلة في هذا القسم.';
    Map<String, String> pick = list[_rnd.nextInt(list.length)];
    if (list.length > 1) {
      var guard = 0;
      while (pick['q'] == _lastAsked[key] && guard++ < 10) {
        pick = list[_rnd.nextInt(list.length)];
      }
    }
    _lastAsked[key] = pick['q']!;
    _quiz = _Quiz(key, pick);
    return '${_cats[key]!.intro}\n\n❓ ${pick['q']}\n\n(تلميح / تخطي / ايقاف)';
  }

  String _hint() {
    final a = _quiz!.current['a']!;
    final chars = a.split('');
    final shown = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      if (chars[i] == ' ') {
        shown.write('  ');
      } else if (i == 0) {
        shown.write(chars[i]);
      } else {
        shown.write(' _');
      }
    }
    return '💡 تلميح: $shown\n(${a.replaceAll(' ', '').length} حروف)';
  }

  String _checkAnswer(String userNorm) {
    final q = _quiz!;
    final answer = q.current['a']!;
    final a = normalize(answer);
    final u = userNorm;
    final ok = u == a ||
        (a.length >= 4 && u.contains(a)) ||
        (u.length >= 4 && a.contains(u));
    if (!ok) return '❌ غلط، جرّب مرة ثانية (أو اكتب: تلميح / تخطي)';
    points += 10;
    _savePoints();
    return '✅ صح! الإجابة: $answer\n⭐ +10 نقاط (المجموع: $points)\n\n${_nextQuestion(q.key)}';
  }

  // ---------------- تخمين ----------------
  String _guess(int n) {
    _tries++;
    final s = _secret!;
    if (n == s) {
      final gain = max(50 - _tries * 5, 10);
      points += gain;
      _savePoints();
      _secret = null;
      return '🎉 صح! الرقم $s بعد $_tries محاولة\n⭐ +$gain نقطة (المجموع: $points)';
    }
    return n < s ? '⬆️ أكبر من $n' : '⬇️ أصغر من $n';
  }

  // ---------------- حجر ورقة مقص ----------------
  String _rps(String cmd) {
    const names = ['حجر', 'ورقه', 'مقص'];
    const icons = {'حجر': '🪨', 'ورقه': '📄', 'مقص': '✂️'};
    final me = names[_rnd.nextInt(3)];
    final String result;
    if (me == cmd) {
      result = '🤝 تعادل';
    } else if ((cmd == 'حجر' && me == 'مقص') ||
        (cmd == 'ورقه' && me == 'حجر') ||
        (cmd == 'مقص' && me == 'ورقه')) {
      points += 5;
      _savePoints();
      result = '🏆 فزت! (+5 نقاط)';
    } else {
      result = '😈 خسرت!';
    }
    return 'أنت: ${icons[cmd]}   أنا: ${icons[me]}\n$result';
  }

  // ---------------- اكس او ----------------
  String _renderXo() {
    final b = _xo!;
    String c(int i) => b[i].isEmpty ? _numEmoji[i] : (b[i] == 'X' ? '❌' : '⭕');
    return '${c(0)}${c(1)}${c(2)}\n${c(3)}${c(4)}${c(5)}\n${c(6)}${c(7)}${c(8)}';
  }

  String? _winner(List<String> b) {
    for (final l in _lines) {
      if (b[l[0]].isNotEmpty && b[l[0]] == b[l[1]] && b[l[1]] == b[l[2]]) {
        return b[l[0]];
      }
    }
    return null;
  }

  int? _findMove(List<String> b, String who) {
    for (final l in _lines) {
      final vals = l.map((i) => b[i]).toList();
      if (vals.where((v) => v == who).length == 2 && vals.contains('')) {
        return l[vals.indexOf('')];
      }
    }
    return null;
  }

  String _xoMove(int n) {
    final b = _xo!;
    if (n < 1 || n > 9) return '⚠️ اختر رقم من 1 إلى 9.';
    if (b[n - 1].isNotEmpty) return '⚠️ الخانة مشغولة، اختر ثانية.\n\n${_renderXo()}';
    b[n - 1] = 'X';

    if (_winner(b) == 'X') {
      points += 20;
      _savePoints();
      final board = _renderXo();
      _xo = null;
      return '$board\n\n🏆 فزت! (+20 نقطة)';
    }
    if (!b.contains('')) {
      final board = _renderXo();
      _xo = null;
      return '$board\n\n🤝 تعادل!';
    }

    // دور الجهاز
    int? move = _findMove(b, 'O') ?? _findMove(b, 'X');
    if (move == null && b[4].isEmpty) move = 4;
    if (move == null) {
      final corners = [0, 2, 6, 8].where((i) => b[i].isEmpty).toList();
      if (corners.isNotEmpty) move = corners[_rnd.nextInt(corners.length)];
    }
    if (move == null) {
      final free = [for (var i = 0; i < 9; i++) if (b[i].isEmpty) i];
      move = free[_rnd.nextInt(free.length)];
    }
    b[move] = 'O';

    if (_winner(b) == 'O') {
      final board = _renderXo();
      _xo = null;
      return '$board\n\n😈 فزت عليك! جرّب مرة ثانية.';
    }
    if (!b.contains('')) {
      final board = _renderXo();
      _xo = null;
      return '$board\n\n🤝 تعادل!';
    }
    return _renderXo();
  }
}
