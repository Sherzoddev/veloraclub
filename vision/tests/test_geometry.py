from velora_vision.geometry import box_anchor, point_in_polygon

SQUARE = [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8)]


def test_inside_and_outside():
    assert point_in_polygon(0.5, 0.5, SQUARE)
    assert not point_in_polygon(0.1, 0.5, SQUARE)
    assert not point_in_polygon(0.5, 0.9, SQUARE)


def test_edge_counts_as_inside():
    assert point_in_polygon(0.2, 0.5, SQUARE)
    assert point_in_polygon(0.5, 0.8, SQUARE)


def test_concave_polygon():
    # An L-shape: the notch at the top right is outside.
    poly = [(0, 0), (1, 0), (1, 0.4), (0.4, 0.4), (0.4, 1), (0, 1)]
    assert point_in_polygon(0.2, 0.7, poly)
    assert not point_in_polygon(0.7, 0.7, poly)


def test_degenerate_polygon_is_never_inside():
    assert not point_in_polygon(0.5, 0.5, [(0, 0), (1, 1)])


def test_anchor_foot_and_center():
    assert box_anchor(10, 20, 30, 100, "foot") == (20, 100)
    assert box_anchor(10, 20, 30, 100, "center") == (20, 60)
