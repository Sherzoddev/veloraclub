# Сторонние компоненты

Velora Vision использует:

- **YOLOX** (модели `yolox_s.onnx`, `yolox_tiny.onnx`): Apache License 2.0,
  © Megvii Inc. https://github.com/Megvii-BaseDetection/YOLOX
- **OpenCV** (opencv-python-headless): Apache License 2.0. https://opencv.org
  В составе пакета есть FFmpeg для чтения потоков камер (LGPL).
- **NumPy**: BSD-3-Clause. https://numpy.org
- **Requests**: Apache License 2.0.
- **FFmpeg** (в пакете `imageio-ffmpeg`, файл `ffmpeg-*.exe`): сборка с
  кодеком x264, лицензия GPL. Запускается как отдельная программа для сборки
  роликов. Исходный код FFmpeg: https://ffmpeg.org/download.html#get-sources ,
  исходный код x264: https://code.videolan.org/videolan/x264 . Пакет:
  https://github.com/imageio/imageio-ffmpeg
- **Python**, **tkinter**, **tzdata**: лицензия PSF / Apache 2.0.

Тексты лицензий лежат в папках соответствующих пакетов внутри `_internal`.
