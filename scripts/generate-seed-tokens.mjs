#!/usr/bin/env node
// seed-design rootage 토큰 → Swift 생성기.
// 실행: node scripts/generate-seed-tokens.mjs [seed-design 저장소 경로]
// 출력: env-pilot/DesignSystem/Tokens/{SeedColors,SeedTokens}.swift (커밋 대상)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SEED = process.argv[2] ?? "/Users/duegosystem/git/seed-design";
const GEN = path.join(SEED, "packages/rootage/__generated__");
const ROOT = path.dirname(fileURLToPath(new URL(".", import.meta.url)));
const OUT = path.join(ROOT, "env-pilot/DesignSystem/Tokens");
mkdirSync(OUT, { recursive: true });

const load = (f) => JSON.parse(readFileSync(path.join(GEN, f), "utf8")).data.tokens;
const camel = (s) => s.replace(/-(\w)/g, (_, c) => c.toUpperCase());
const pascal = (s) => { const c = camel(s); return c[0].toUpperCase() + c.slice(1); };
const HEADER = (src) => `// Generated from seed-design rootage (${src}) — 수정 금지.
// 재생성: node scripts/generate-seed-tokens.mjs

import SwiftUI
`;

// ---------- SeedColors.swift ----------
const colors = load("color.json");
const resolveHex = (value, theme) => {
  while (value.startsWith("$")) value = colors[value].values[theme].value;
  const hex = value.slice(1).padEnd(8, "f"); // #rrggbb → rrggbbff
  return "0x" + hex.toUpperCase();
};
const EXCLUDE = new Set(["manner-temp", "banner"]);
const semantic = [], palette = [];
for (const key of Object.keys(colors)) {
  const [, category, ...rest] = key.slice(1).split("."); // "$color.bg.brand-solid"
  if (EXCLUDE.has(category)) continue;
  const name = rest.join(".");
  const light = resolveHex(colors[key].values["theme-light"].value, "theme-light");
  const dark = resolveHex(colors[key].values["theme-dark"].value, "theme-dark");
  const line = `Color(light: ${light}, dark: ${dark})`;
  if (category === "palette") palette.push(`        static let ${camel(name)} = ${line}`);
  else semantic.push(`    static let ${camel(category)}${pascal(name)} = ${line}`);
}
writeFileSync(path.join(OUT, "SeedColors.swift"), `${HEADER("color.json")}
enum SeedColor {
${semantic.join("\n")}

    /// 팔레트 스케일 — 시맨틱 토큰으로 표현 불가한 예외에서만 사용 (seed 규칙).
    enum Palette {
${palette.join("\n")}
    }
}
`);

// ---------- SeedTokens.swift ----------
const px = (t) => t.values.default.value.value; // {value, unit:"px"}
const dimension = load("dimension.json");
const spacing = Object.keys(dimension)
  .filter((k) => /^\$dimension\.x[0-9_]+$/.test(k))
  .map((k) => `    static let ${k.split(".")[1]}: CGFloat = ${px(dimension[k])}`);

const radius = Object.entries(load("radius.json"))
  .map(([k, t]) => `    static let ${k.split(".")[1]}: CGFloat = ${px(t)}`);

const fontSizes = Object.entries(load("font-size.json"))
  .filter(([k]) => !k.includes("-static"))
  .map(([k, t]) => [k.split(".")[1], t.values.default.value.value * 16]);
const fontSize = fontSizes.map(([n, v]) => `    static let ${n}: CGFloat = ${v}`);
const fontFns = fontSizes.map(
  ([n]) => `    static func ${n}(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.${n}, weight: weight) }`
);

const WEIGHT = { 400: ".regular", 500: ".medium", 700: ".bold" };
const fontWeight = Object.entries(load("font-weight.json"))
  .map(([k, t]) => `    static let ${camel(k.split(".")[1])}: Font.Weight = ${WEIGHT[t.values.default.value]}`);

const durations = load("duration.json");
const resolveMs = (t) => {
  let v = t.values.default.value;
  while (typeof v === "string") v = durations[v].values.default.value;
  return v.value / 1000;
};
const duration = Object.entries(durations)
  .map(([k, t]) => `    static let ${camel(k.split(".")[1])}: TimeInterval = ${resolveMs(t)}`);

const easing = Object.entries(load("timing-function.json")).map(([k, t]) => {
  const [x1, y1, x2, y2] = t.values.default.value;
  const name = camel(k.split(".")[1]);
  const dflt = { easing: "SeedDuration.colorTransition", pressedScale: "SeedDuration.pressedScale" }[name] ?? "SeedDuration.d5";
  return `    static func ${name}(_ duration: TimeInterval = ${dflt}) -> Animation { .timingCurve(${x1}, ${y1}, ${x2}, ${y2}, duration: duration) }`;
});

const scale = Object.entries(load("scale.json"))
  .map(([k, t]) => `    static let ${k.split(".")[1]}: CGFloat = ${t.values.preferred.value}`);

const shadow = Object.entries(load("shadow.json")).map(([k, t]) => {
  const l = t.values["theme-light"].value[0], d = t.values["theme-dark"].value[0];
  const hex = (c) => "0x" + c.slice(1).padEnd(8, "f").toUpperCase();
  return `    static let ${k.split(".")[1]} = SeedShadowToken(color: Color(light: ${hex(l.color)}, dark: ${hex(d.color)}), y: ${l.offsetY.value}, blur: ${l.blur.value})`;
});

writeFileSync(path.join(OUT, "SeedTokens.swift"), `${HEADER("dimension/radius/font/duration/timing-function/scale/shadow.json")}
/// 4px 그리드 간격 (x1 = 4pt)
enum SeedSpacing {
${spacing.join("\n")}
}

enum SeedRadius {
${radius.join("\n")}
}

enum SeedFontSize {
${fontSize.join("\n")}
}

enum SeedFont {
${fontFns.join("\n")}
}

enum SeedFontWeight {
${fontWeight.join("\n")}
}

enum SeedDuration {
${duration.join("\n")}
}

enum SeedEasing {
${easing.join("\n")}
}

/// 눌림 스케일 (reduced motion 시 컴포넌트에서 accessibilityReduceMotion으로 1.0 처리)
enum SeedScale {
${scale.join("\n")}
}

struct SeedShadowToken {
    let color: Color
    let y: CGFloat
    let blur: CGFloat
}

enum SeedShadow {
${shadow.join("\n")}
}

extension View {
    /// seed 그림자 (CSS blur → SwiftUI radius 근사: blur/2)
    func seedShadow(_ token: SeedShadowToken) -> some View {
        shadow(color: token.color, radius: token.blur / 2, y: token.y)
    }
}
`);

console.log("Generated SeedColors.swift, SeedTokens.swift →", OUT);
