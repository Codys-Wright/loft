# theme.json → walker colors.css (@define-color studio_*). Fallback until the
# theme engine renders walker.css itself; same names it will emit.
def rgba(hex; a):
  (hex | ltrimstr("#")) as $h
  | [($h[0:2]), ($h[2:4]), ($h[4:6])]
  | map(explode | map(if . >= 97 then . - 87 elif . >= 65 then . - 55 else . - 48 end) | .[0] * 16 + .[1])
  | "rgba(\(.[0]), \(.[1]), \(.[2]), \(a))";
def clamp(x; lo; hi): if x < lo then lo elif x > hi then hi else x end;

.palette as $p
| (.glass // {}) as $g
| [
    "@define-color studio_bg \($p.bg);",
    "@define-color studio_surface \($p.surface);",
    "@define-color studio_overlay \($p.overlay);",
    "@define-color studio_text \($p.text);",
    "@define-color studio_subtext \($p.subtext);",
    "@define-color studio_accent \($p.accent);",
    "@define-color studio_accent_text \($p.bg);",
    "@define-color studio_urgent \($p.urgent);",
    "@define-color studio_glass \(rgba($g.tint // $p.bg; clamp(($g.opacity // 0.45) * 1.6; 0; 0.92)));",
    "@define-color studio_glass_border \(rgba($g.border // "#ffffff"; $g.borderOpacity // 0.14));",
    "@define-color studio_selection \(rgba($p.text; 0.12));"
  ]
| join("\n")
