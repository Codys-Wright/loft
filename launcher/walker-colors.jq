# theme.json → walker colors.css (@define-color loft_*). Fallback until the
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
    "@define-color loft_bg \($p.bg);",
    "@define-color loft_surface \($p.surface);",
    "@define-color loft_overlay \($p.overlay);",
    "@define-color loft_text \($p.text);",
    "@define-color loft_subtext \($p.subtext);",
    "@define-color loft_accent \($p.accent);",
    "@define-color loft_accent_text \($p.bg);",
    "@define-color loft_urgent \($p.urgent);",
    "@define-color loft_glass \(rgba($g.tint // $p.bg; clamp(($g.opacity // 0.45) * 1.6; 0; 0.92)));",
    "@define-color loft_glass_border \(rgba($g.border // "#ffffff"; $g.borderOpacity // 0.14));",
    "@define-color loft_selection \(rgba($p.text; 0.12));"
  ]
| join("\n")
