import shutil

import numpy as np
import pytest

from velora_vision.detector import PersonDetector
from velora_vision.paths import model_file

path, size = model_file("fast")


@pytest.mark.skipif(not path.exists(), reason="models are not downloaded (scripts/get_models.py)")
def test_the_model_loads_from_a_folder_with_russian_letters(tmp_path):
    # OpenCV fails to open such a path on Windows; the file is read by us.
    folder = tmp_path / "Рабочий стол" / "Иван"
    folder.mkdir(parents=True)
    copy = folder / path.name
    shutil.copy(path, copy)
    detector = PersonDetector(str(copy), 0.4, size)
    assert detector.detect(np.zeros((480, 640, 3), np.uint8)) == []
