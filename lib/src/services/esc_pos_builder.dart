// A small, dependency-free ESC/POS command builder — just the commands a
// receipt actually needs (align, bold, size, cut, native QR) plus Cyrillic
// text encoded as CP866, which is what the overwhelming majority of cheap
// thermal receipt printers use for their built-in Cyrillic code page.
//
// This targets both transports the same way: the exact same byte stream is
// sent whether it goes to a Windows-installed printer as a RAW spool job or
// straight to a COM port — a real ESC/POS printer doesn't care which cable
// carried the bytes.

import 'dart:convert';
import 'dart:typed_data';

enum EscAlign { left, center, right }

class EscPosBuilder {
  final BytesBuilder _out = BytesBuilder();
  static final _cp866 = _Cp866Codec();

  EscPosBuilder() {
    // ESC @ — reset the printer to its power-on state before anything else.
    _out.add([0x1B, 0x40]);
    // FS . — cancel Kanji (double-byte) character mode. Cheap ESC/POS
    // clones built primarily for the Chinese market often power on with
    // this mode active; while it's on, the printer reads Cyrillic bytes as
    // the first half of two-byte Chinese characters no matter what code
    // page gets selected next -- which is exactly what "chek chiqishida
    // xitoycha belgilar" (Chinese characters on the receipt) was.
    _out.add([0x1C, 0x2E]);
    // ESC t 17 — select CP866 as the active character table.
    _out.add([0x1B, 0x74, 17]);
  }

  Uint8List build() => _out.toBytes();

  EscPosBuilder text(String value, {bool newline = true}) {
    // money() keeps sums on one line on screen with no-break spaces; the
    // printer's code page has no such character.
    _out.add(_cp866.encode(value.replaceAll('\u00a0', ' ')));
    if (newline) _out.add([0x0A]);
    return this;
  }

  EscPosBuilder align(EscAlign value) {
    final n = switch (value) {
      EscAlign.left => 0,
      EscAlign.center => 1,
      EscAlign.right => 2,
    };
    _out.add([0x1B, 0x61, n]);
    return this;
  }

  EscPosBuilder bold(bool on) {
    _out.add([0x1B, 0x45, on ? 1 : 0]);
    return this;
  }

  /// `wide`/`tall` double the character's width/height (native ESC/POS
  /// double-size, not a bitmap scale — stays crisp on any thermal head).
  EscPosBuilder size({bool wide = false, bool tall = false}) {
    var n = 0;
    if (wide) n |= 0x10;
    if (tall) n |= 0x01;
    _out.add([0x1D, 0x21, n]);
    return this;
  }

  EscPosBuilder divider(int width, [String char = '-']) => text(char * width);

  EscPosBuilder feed([int lines = 1]) {
    _out.add([0x1B, 0x64, lines]);
    return this;
  }

  /// GS V — partial cut, leaving a small connecting strip (the common
  /// "tear here" cut most kitchen/receipt printers do by default).
  EscPosBuilder cut() {
    _out.add([0x1D, 0x56, 0x01]);
    return this;
  }

  /// A native ESC/POS QR code (GS ( k), model 2, printed at [moduleSize]
  /// dots per module. Every ESC/POS printer since ~2012 that advertises 2D
  /// barcode support implements this the same way, so no external QR
  /// rendering library is needed.
  EscPosBuilder qrCode(String data, {int moduleSize = 6}) {
    final payload = utf8.encode(data);
    final storeLen = payload.length + 3;

    void gsk(List<int> body) {
      _out.add(
          [0x1D, 0x28, 0x6B, body.length & 0xFF, (body.length >> 8) & 0xFF]);
      _out.add(body);
    }

    gsk([0x31, 0x41, 0x32, 0x00]); // model 2
    gsk([0x31, 0x43, moduleSize]); // module size
    gsk([0x31, 0x45, 0x31]); // error correction: M
    _out.add([
      0x1D,
      0x28,
      0x6B,
      storeLen & 0xFF,
      (storeLen >> 8) & 0xFF,
      0x31,
      0x50,
      0x30,
      ...payload,
    ]); // store data
    gsk([0x31, 0x51, 0x30]); // print stored data

    return this;
  }
}

/// Minimal CP866 encoder: ASCII passes through unchanged, Cyrillic maps to
/// the 0x80–0xFF range exactly as the printer's built-in table expects.
/// Anything outside that (emoji, exotic Latin diacritics) falls back to `?`
/// rather than corrupting the byte stream — a receipt has no use for them
/// anyway.
class _Cp866Codec {
  static const _upperAE = 0x410; // А
  static const _lowerAE = 0x430; // а
  static const _upperYO = 0x401; // Ё
  static const _lowerYO = 0x451; // ё
  static const _numeroSign = 0x2116; // №

  List<int> encode(String value) {
    final bytes = <int>[];
    for (final rune in value.runes) {
      if (rune < 0x80) {
        bytes.add(rune);
      } else if (rune == _upperYO) {
        bytes.add(0xF0);
      } else if (rune == _lowerYO) {
        bytes.add(0xF1);
      } else if (rune == _numeroSign) {
        bytes.add(0xFC);
      } else if (rune >= _upperAE && rune <= _upperAE + 0x1F) {
        bytes.add(0x80 + (rune - _upperAE)); // А–Я
      } else if (rune >= _lowerAE && rune <= _lowerAE + 0x1F) {
        final offset = rune - _lowerAE;
        // CP866 keeps а–п at 0xA0–0xAF and р–я at 0xE0–0xEF.
        bytes.add(offset < 16 ? 0xA0 + offset : 0xE0 + (offset - 16));
      } else {
        bytes.add(0x3F); // '?'
      }
    }
    return bytes;
  }
}
