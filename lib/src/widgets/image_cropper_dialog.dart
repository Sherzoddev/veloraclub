import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';

/// Crop editor for a product photo, opened right after picking a file.
///
/// Different source photos (different sizes, different framing) used to make
/// the sale grid look inconsistent — some filled the card, others floated
/// tiny in the middle with empty space around them. Cropping every photo to
/// the same fixed 3:2 frame here, before upload, makes every product card
/// look uniform — mirrors the crop step the club's other (web) POS already
/// has for the same reason.
class ImageCropperDialog extends StatefulWidget {
  const ImageCropperDialog({super.key, required this.bytes});

  final Uint8List bytes;

  static const canvasW = 320.0;
  static const canvasH = 320.0; // square, matches ProductGridCard's photo area
  static const outputScale = 2.5; // -> 800x800 output

  @override
  State<ImageCropperDialog> createState() => _ImageCropperDialogState();
}

class _ImageCropperDialogState extends State<ImageCropperDialog> {
  final _boundaryKey = GlobalKey();
  ui.Image? _image;
  double _baseScale = 1;
  double _zoom = 1;
  Offset _offset = Offset.zero;
  Offset? _dragOrigin;
  Offset? _dragStart;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final codec = await ui.instantiateImageCodec(widget.bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    // Whole photo visible by default (contain-fit) rather than filling the
    // frame edge-to-edge (cover-fit) -- with a source photo's aspect ratio
    // rarely matching the 3:2 card exactly, cover-fit silently cropped off
    // part of the product on every upload unless the cashier noticed and
    // zoomed back out themselves. Now zooming in is opt-in.
    final scale = (ImageCropperDialog.canvasW / image.width) <
            (ImageCropperDialog.canvasH / image.height)
        ? ImageCropperDialog.canvasW / image.width
        : ImageCropperDialog.canvasH / image.height;
    if (!mounted) return;
    setState(() {
      _image = image;
      _baseScale = scale;
      _offset = Offset(
        (ImageCropperDialog.canvasW - image.width * scale) / 2,
        (ImageCropperDialog.canvasH - image.height * scale) / 2,
      );
    });
  }

  Offset _clamp(Offset next, double scale) {
    final image = _image;
    if (image == null) return next;
    final w = image.width * scale;
    final h = image.height * scale;
    // Below canvas size on an axis (image narrower/shorter than the 3:2
    // frame at this zoom): center it there instead of clamping to a
    // min > max range, which panning past cover-fit used to hit.
    double axis(double value, double size, double canvasSize) {
      if (size <= canvasSize) return (canvasSize - size) / 2;
      return value.clamp(canvasSize - size, 0);
    }

    return Offset(
      axis(next.dx, w, ImageCropperDialog.canvasW),
      axis(next.dy, h, ImageCropperDialog.canvasH),
    );
  }

  void _onZoomChanged(double v) {
    final image = _image;
    if (image == null) return;
    final oldScale = _baseScale * _zoom;
    final newScale = _baseScale * v;
    const cx = ImageCropperDialog.canvasW / 2;
    const cy = ImageCropperDialog.canvasH / 2;
    final relX = (cx - _offset.dx) / oldScale;
    final relY = (cy - _offset.dy) / oldScale;
    setState(() {
      _zoom = v;
      _offset =
          _clamp(Offset(cx - relX * newScale, cy - relY * newScale), newScale);
    });
  }

  Future<void> _confirm() async {
    final boundary = _boundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;
    final captured =
        await boundary.toImage(pixelRatio: ImageCropperDialog.outputScale);
    final bytes = await captured.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null || !mounted) return;
    Navigator.pop(context, bytes.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return AlertDialog(
      title: const Text('Rasmni kadrlash'),
      content: SizedBox(
        width: ImageCropperDialog.canvasW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              key: _boundaryKey,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: ImageCropperDialog.canvasW,
                  height: ImageCropperDialog.canvasH,
                  color: VColors.field,
                  child: image == null
                      ? const Center(child: CircularProgressIndicator())
                      : GestureDetector(
                          onPanStart: (d) {
                            _dragStart = d.localPosition;
                            _dragOrigin = _offset;
                          },
                          onPanUpdate: (d) {
                            final start = _dragStart;
                            final origin = _dragOrigin;
                            if (start == null || origin == null) return;
                            final scale = _baseScale * _zoom;
                            setState(() {
                              _offset = _clamp(
                                  origin + (d.localPosition - start), scale);
                            });
                          },
                          child: CustomPaint(
                            size: const Size(ImageCropperDialog.canvasW,
                                ImageCropperDialog.canvasH),
                            painter: _CropPainter(
                              image: image,
                              scale: _baseScale * _zoom,
                              offset: _offset,
                            ),
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.zoom_out_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _zoom,
                    min: 1,
                    max: 3,
                    onChanged: image == null ? null : _onZoomChanged,
                  ),
                ),
                const Icon(Icons.zoom_in_rounded, size: 18),
              ],
            ),
            Text('Suring va kattalashtiring',
                style: TextStyle(color: VColors.subtle, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Bekor qilish'),
        ),
        FilledButton(
          onPressed: image == null ? null : _confirm,
          child: const Text('Tayyor'),
        ),
      ],
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(
      {required this.image, required this.scale, required this.offset});
  final ui.Image image;
  final double scale;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(
        offset.dx, offset.dy, image.width * scale, image.height * scale);
    canvas.drawImageRect(image, src, dst, Paint());
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.scale != scale ||
      oldDelegate.offset != offset;
}
