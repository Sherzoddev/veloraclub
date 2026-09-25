// Raw receipt printing — no PDF, no OS print dialog. Two transports:
//
//  * `windows`: a printer already installed in Windows (thermal printers are
//    usually installed with a "Generic / Text Only" driver, sometimes with a
//    real ESC/POS driver). Bytes go straight to the spooler as RAW data via
//    winspool.drv, exactly like a thermal printer driver would send them —
//    no rasterization, no page breaks the driver invents on its own.
//  * `usb` / `bluetooth`: the printer has no Windows driver at all and shows
//    up as a COM port (a USB-to-serial chip such as CH340, or a paired
//    Bluetooth SPP device). Bytes go straight over that serial connection.
//
// Both paths take the same input: a pre-built ESC/POS byte stream from
// [EscPosBuilder]. Nothing here knows about receipts, tables or Supabase —
// it only knows how to get bytes to a device.

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

enum PrinterTransport { windows, usb, bluetooth }

class PrinterConfig {
  PrinterConfig({
    this.transport = PrinterTransport.windows,
    this.windowsPrinterName,
    this.serialPort,
    this.baudRate = 9600,
    this.showOnScreen = true,
    this.paperWidthMm = 58,
  });

  PrinterTransport transport;
  String? windowsPrinterName;
  String? serialPort;
  int baudRate;
  bool showOnScreen;
  int paperWidthMm;

  static const _kTransport = 'printer_transport';
  static const _kWindowsName = 'printer_windows_name';
  static const _kSerialPort = 'printer_serial_port';
  static const _kBaud = 'printer_baud_rate';
  static const _kShowOnScreen = 'printer_show_on_screen';
  static const _kPaperWidth = 'printer_paper_width_mm';

  static Future<PrinterConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final transportName = prefs.getString(_kTransport);
    return PrinterConfig(
      transport: PrinterTransport.values.firstWhere(
        (t) => t.name == transportName,
        orElse: () => PrinterTransport.windows,
      ),
      windowsPrinterName: prefs.getString(_kWindowsName),
      serialPort: prefs.getString(_kSerialPort),
      baudRate: prefs.getInt(_kBaud) ?? 9600,
      showOnScreen: prefs.getBool(_kShowOnScreen) ?? true,
      paperWidthMm: prefs.getInt(_kPaperWidth) ?? 58,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTransport, transport.name);
    if (windowsPrinterName != null) {
      await prefs.setString(_kWindowsName, windowsPrinterName!);
    }
    if (serialPort != null) await prefs.setString(_kSerialPort, serialPort!);
    await prefs.setInt(_kBaud, baudRate);
    await prefs.setBool(_kShowOnScreen, showOnScreen);
    await prefs.setInt(_kPaperWidth, paperWidthMm);
  }

  bool get isConfigured => switch (transport) {
        PrinterTransport.windows =>
          windowsPrinterName != null && windowsPrinterName!.isNotEmpty,
        PrinterTransport.usb ||
        PrinterTransport.bluetooth =>
          serialPort != null && serialPort!.isNotEmpty,
      };
}

class PrinterException implements Exception {
  PrinterException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract final class PrinterService {
  /// Printers already installed in Windows (Settings → Printers & scanners),
  /// via `EnumPrintersW` — the same list `raw-print.ps1`-style tools see.
  static List<String> listWindowsPrinters() {
    if (!Platform.isWindows) return const [];
    final flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
    final needed = calloc<Uint32>();
    final returned = calloc<Uint32>();
    try {
      EnumPrinters(flags, null, 4, null, 0, needed, returned);
      if (needed.value == 0) return const [];

      final buffer = calloc<Uint8>(needed.value);
      try {
        final result = EnumPrinters(
            flags, null, 4, buffer, needed.value, needed, returned);
        if (!result.value) return const [];

        final names = <String>[];
        final structSize = sizeOf<PRINTER_INFO_4>();
        for (var i = 0; i < returned.value; i++) {
          final info = Pointer<PRINTER_INFO_4>.fromAddress(
                  buffer.address + i * structSize)
              .ref;
          if (info.pPrinterName.address != 0) {
            names.add(info.pPrinterName.toDartString());
          }
        }
        return names;
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(needed);
      calloc.free(returned);
    }
  }

  /// Sends [bytes] to a Windows-installed printer as a single RAW spool job —
  /// no driver rendering, no rasterization. Requires the printer to accept
  /// RAW data (any ESC/POS or "Generic / Text Only" printer does).
  static Future<void> printRawToWindows(
      String printerName, Uint8List bytes) async {
    if (!Platform.isWindows) {
      throw PrinterException('Windows printeri faqat kompyuterda ishlaydi');
    }
    final nameP = PCWSTR(printerName.toNativeUtf16());
    final docNameP = PWSTR('Velora Club Chek'.toNativeUtf16());
    final dataTypeP = PWSTR('RAW'.toNativeUtf16());
    final phPrinter = calloc<Pointer>();
    final docInfo = calloc<DOC_INFO_1>();
    try {
      docInfo.ref
        ..pDocName = docNameP
        ..pOutputFile = PWSTR(nullptr)
        ..pDatatype = dataTypeP;

      final opened = OpenPrinter(nameP, phPrinter, null);
      if (!opened.value) {
        throw PrinterException('Printerni ochib bo\'lmadi: $printerName');
      }
      final hPrinter = PRINTER_HANDLE(phPrinter.value);
      try {
        final jobId = StartDocPrinter(hPrinter, 1, docInfo);
        if (jobId == 0) {
          throw PrinterException('Chop etish vazifasini boshlab bo\'lmadi');
        }
        try {
          if (!StartPagePrinter(hPrinter)) {
            throw PrinterException('Sahifani boshlab bo\'lmadi');
          }
          try {
            final dataP = calloc<Uint8>(bytes.length);
            final written = calloc<Uint32>();
            try {
              dataP.asTypedList(bytes.length).setAll(0, bytes);
              final ok =
                  WritePrinter(hPrinter, dataP.cast(), bytes.length, written);
              if (!ok || written.value != bytes.length) {
                throw PrinterException('Ma\'lumotlarni yozib bo\'lmadi');
              }
            } finally {
              calloc.free(dataP);
              calloc.free(written);
            }
          } finally {
            EndPagePrinter(hPrinter);
          }
        } finally {
          EndDocPrinter(hPrinter);
        }
      } finally {
        ClosePrinter(hPrinter);
      }
    } finally {
      calloc.free(nameP);
      calloc.free(docNameP);
      calloc.free(dataTypeP);
      calloc.free(phPrinter);
      calloc.free(docInfo);
    }
  }

  /// COM ports currently visible to Windows — USB-to-serial adapters (CH340,
  /// FTDI, …) and paired Bluetooth SPP devices both show up here identically,
  /// which is why the "USB-kabel" and "Bluetooth (COM-port)" tabs share this
  /// same picker.
  static List<String> listSerialPorts() {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return const [];
    }
    try {
      return SerialPort.availablePorts;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> printRawToSerial(
    String portName,
    Uint8List bytes, {
    int baudRate = 9600,
  }) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      throw PrinterException('COM-port faqat kompyuterda ishlaydi');
    }
    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      final error = SerialPort.lastError;
      throw PrinterException(
          'Portni ochib bo\'lmadi: $portName${error != null ? ' ($error)' : ''}');
    }
    try {
      // `port.config = ...` makes the port take ownership of this config and
      // dispose it later (in port.dispose(), below) -- disposing it here too
      // would free the same native struct twice, corrupting the heap.
      port.config = SerialPortConfig()
        ..baudRate = baudRate
        ..bits = 8
        ..parity = SerialPortParity.none
        ..stopBits = 1
        ..setFlowControl(SerialPortFlowControl.none);
      final written = port.write(bytes);
      if (written != bytes.length) {
        throw PrinterException(
            'Barcha ma\'lumot yuborilmadi ($written/${bytes.length} bayt)');
      }
    } finally {
      port.close();
      port.dispose();
    }
  }

  static Future<void> print(PrinterConfig config, Uint8List bytes) {
    switch (config.transport) {
      case PrinterTransport.windows:
        final name = config.windowsPrinterName;
        if (name == null || name.isEmpty) {
          throw PrinterException('Printer tanlanmagan');
        }
        return printRawToWindows(name, bytes);
      case PrinterTransport.usb:
      case PrinterTransport.bluetooth:
        final port = config.serialPort;
        if (port == null || port.isEmpty) {
          throw PrinterException('COM-port tanlanmagan');
        }
        return printRawToSerial(port, bytes, baudRate: config.baudRate);
    }
  }
}
