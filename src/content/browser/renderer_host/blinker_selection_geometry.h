// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_BROWSER_RENDERER_HOST_BLINKER_SELECTION_GEOMETRY_H_
#define CONTENT_BROWSER_RENDERER_HOST_BLINKER_SELECTION_GEOMETRY_H_

#include <algorithm>
#include <cmath>

// iOS до 17.3, маркери малює сам Blinker. Тільки std, щоб тестити на хості
namespace content::blinker_selection {

struct Point {
  float x = 0.f;
  float y = 0.f;
};

struct Rect {
  float x = 0.f;
  float y = 0.f;
  float width = 0.f;
  float height = 0.f;
};

struct Bound {
  Point top;
  Point bottom;
};

enum class Handle { kNone, kStart, kEnd };

inline constexpr float kKnobDiameter = 11.f;
// половина 44 pt з Apple HIG
inline constexpr float kGrabRadius = 22.f;
inline constexpr float kTapSlop = 8.f;
inline constexpr float kAutoscrollBeltTop = 20.f;
inline constexpr float kAutoscrollBeltBottom = 60.f;

inline float Distance(Point a, Point b) {
  return std::hypot(a.x - b.x, a.y - b.y);
}

// не більше 8 DIP, щоб на високому рядку не влучити в рядок вище
inline Point LinePoint(const Bound& bound) {
  constexpr float kMaxLineOffset = 8.f;
  const float dx = std::clamp((bound.top.x - bound.bottom.x) / 2.f,
                              -kMaxLineOffset, kMaxLineOffset);
  const float dy = std::clamp((bound.top.y - bound.bottom.y) / 2.f,
                              -kMaxLineOffset, kMaxLineOffset);
  return {bound.bottom.x + dx, bound.bottom.y + dy};
}

inline Point KnobCenter(const Bound& bound, bool is_start) {
  return is_start ? Point{bound.top.x, bound.top.y - kKnobDiameter / 2.f}
                  : Point{bound.bottom.x, bound.bottom.y + kKnobDiameter / 2.f};
}

inline float DistanceToHandle(const Bound& bound, bool is_start, Point p) {
  const Point a =
      is_start ? Point{bound.top.x, bound.top.y - kKnobDiameter} : bound.top;
  const Point b = is_start
                      ? bound.bottom
                      : Point{bound.bottom.x, bound.bottom.y + kKnobDiameter};
  const float vx = b.x - a.x;
  const float vy = b.y - a.y;
  const float length_squared = vx * vx + vy * vy;
  float t = 0.f;
  if (length_squared > 0.f) {
    t = std::clamp(((p.x - a.x) * vx + (p.y - a.y) * vy) / length_squared, 0.f,
                   1.f);
  }
  return Distance(p, Point{a.x + t * vx, a.y + t * vy});
}

// start і end в логічному порядку, тому в RTL початок справа
inline Handle HandleAtPoint(const Bound& start, const Bound& end, Point p) {
  const float to_start = DistanceToHandle(start, /*is_start=*/true, p);
  const float to_end = DistanceToHandle(end, /*is_start=*/false, p);
  const bool start_hit = to_start <= kGrabRadius;
  const bool end_hit = to_end <= kGrabRadius;
  if (!start_hit && !end_hit) {
    return Handle::kNone;
  }
  if (start_hit != end_hit) {
    return start_hit ? Handle::kStart : Handle::kEnd;
  }
  if (std::fabs(to_start - to_end) >= 1.f) {
    return to_start < to_end ? Handle::kStart : Handle::kEnd;
  }
  return Distance(p, KnobCenter(start, true)) <=
                 Distance(p, KnobCenter(end, false))
             ? Handle::kStart
             : Handle::kEnd;
}

inline Point DragOffset(Point touch_down, Point line_point) {
  return {line_point.x - touch_down.x, line_point.y - touch_down.y};
}

inline Point ApplyOffset(Point touch, Point offset) {
  return {touch.x + offset.x, touch.y + offset.y};
}

inline bool InAutoscrollBelt(Point p, const Rect& view) {
  return p.y < view.y + kAutoscrollBeltTop ||
         p.y > view.y + view.height - kAutoscrollBeltBottom;
}

inline bool ExtendStartForLongPressDrag(Point anchor,
                                        Point delta,
                                        Point start,
                                        Point end) {
  if (std::fabs(delta.y) > std::fabs(delta.x)) {
    return delta.y < 0.f;
  }
  const Point start_delta{start.x - anchor.x, start.y - anchor.y};
  const Point end_delta{end.x - anchor.x, end.y - anchor.y};
  const auto normalized_dot = [](Point v, Point d) {
    const float length = std::hypot(v.x, v.y);
    if (length == 0.f) {
      return 0.f;
    }
    return (v.x * d.x + v.y * d.y) / length;
  };
  const float start_dot = normalized_dot(start_delta, delta);
  const float end_dot = normalized_dot(end_delta, delta);
  if (start_dot >= 0.f || end_dot >= 0.f) {
    return start_dot > end_dot;
  }
  return std::hypot(start_delta.x, start_delta.y) <
         std::hypot(end_delta.x, end_delta.y);
}

inline Rect LoupeFrame(Point focus,
                       float line_top,
                       float line_bottom,
                       const Rect& bounds,
                       float width,
                       float height,
                       float gap) {
  Rect frame{focus.x - width / 2.f, line_top - gap - height, width, height};
  const float min_x = bounds.x;
  const float max_x = bounds.x + bounds.width - width;
  frame.x = max_x < min_x ? min_x : std::clamp(frame.x, min_x, max_x);
  if (frame.y < bounds.y) {
    frame.y = line_bottom + gap;
  }
  return frame;
}

inline Rect LoupeSource(Point center, float width, float height, float zoom) {
  const float source_width = width / zoom;
  const float source_height = height / zoom;
  return {center.x - source_width / 2.f, center.y - source_height / 2.f,
          source_width, source_height};
}

}  // namespace content::blinker_selection

#endif  // CONTENT_BROWSER_RENDERER_HOST_BLINKER_SELECTION_GEOMETRY_H_
