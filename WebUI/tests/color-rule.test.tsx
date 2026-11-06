import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

// Enforces the Color rule in Design/DESIGN_SYSTEM.md.
const read = (name: string) => readFileSync(resolve(__dirname, "../src", name), "utf8");
const tokens = read("tokens.css");
const glass = read("glass.css");
const styles = read("styles.css");

const hexes = (value: string) => value.match(/#[0-9a-fA-F]{3,8}\b/g) ?? [];
function channels(hex: string) {
  const digits = hex.slice(1);
  const full = digits.length < 6 ? [...digits.slice(0, 3)].map((d) => d + d).join("") : digits.slice(0, 6);
  return [0, 2, 4].map((at) => parseInt(full.slice(at, at + 2), 16));
}
// Surfaces may lean slightly toward navy, never toward any other hue.
const isTinted = (hex: string) => {
  const [r, g, b] = channels(hex);
  return Math.max(r, g, b) - Math.min(r, g, b) > 8 && !(b >= g && g >= r && b - r <= 55);
};
const declaration = (css: string, name: string) => [...css.matchAll(new RegExp(`${name}:\\s*([^;]+);`, "g"))].map((match) => match[1]);

describe("color rule", () => {
  const neutral = ["--text", "--muted", "--canvas", "--workspace-background", "--sidebar-surface", "--panel-border", "--line", "--line-strong", "--nav-active", "--nav-active-text", "--nav-hover", "--surface", "--surface-solid", "--surface-subtle", "--surface-raised", "--surface-inset", "--composer-fade", "--badge-background", "--input-border"];

  it.each(neutral)("%s has no color cast in any appearance", (name) => {
    const values = declaration(tokens, name).filter((value) => !value.startsWith("var("));
    expect(values.length).toBeGreaterThan(0);
    for (const value of values) expect(hexes(value).filter(isTinted)).toEqual([]);
  });

  it("uses one blue for primary actions", () => {
    expect(new Set(declaration(tokens, "--primary"))).toEqual(new Set(["#2563ff"]));
  });

  it("has no gradients in tokens, and only the composer fade in component styles", () => {
    expect(tokens).not.toMatch(/gradient\(/);
    const gradients = styles.split("\n").filter((line) => /(?<!repeating-linear-)gradient\(/.test(line));
    expect(gradients.map((line) => line.trim())).toEqual(["background: linear-gradient(transparent, var(--composer-fade));"]);
  });

  it("keeps component styles free of blue literals", () => {
    const blues = hexes(styles.split("\n").filter((line) => !line.includes("--calendar-")).join("\n")).filter((hex) => {
      const [r, g, b] = channels(hex);
      return b - r > 40 && b >= g;
    });
    expect(blues).toEqual([]);
  });

  it("paints nothing decorative behind the content, so the Mac shows through", () => {
    expect(glass.split("\n").filter((line) => /conic-gradient/.test(line))).toEqual([]);
    expect(read("ambient.css")).not.toMatch(/#root::before|url\(/);
    expect(glass).toMatch(/--workspace-background: transparent;/);
    expect(glass).toMatch(/--sidebar-surface: transparent;/);
  });

  it("gives the menu no panel of its own", () => {
    expect(glass).toMatch(/\.sidebar \{ background: transparent; border: 0; box-shadow: none; \}/);
  });

  it("makes every shared surface token glass", () => {
    for (const name of ["--surface", "--surface-raised", "--surface-subtle", "--surface-inset", "--sidebar-surface"]) {
      expect(glass).toMatch(new RegExp(`html:root:root\\[data-glass="on"\\] \\{[^}]*${name}:`));
    }
  });

  it("renders sent messages as glass, not a color block", () => {
    const rule = styles.match(/\.message\.user \{[^}]*\}/)?.[0] ?? "";
    expect(rule).toContain("var(--surface-raised)");
    expect(rule).not.toContain("--primary");
    expect(glass).toMatch(/\.message\.user \{[^}]*var\(--glass-sheen\)/);
  });

  it("falls back to solid surfaces for macOS accessibility settings", () => {
    const overrides = glass.match(/--glass-opacity: 1 !important;[^}]*/g) ?? [];
    expect(overrides).toHaveLength(2);
    for (const override of overrides) expect(override).toContain("--surface-raised: var(--surface-solid)");
  });
});

describe("type and size rule", () => {
  const all = ["styles.css", "notch.css", "glass.css", "ambient.css"].map(read).join("\n");

  it("uses only the shared type sizes", () => {
    const literal = [...all.matchAll(/font-size:\s*([^;}]+)/g)].map((match) => match[1].trim()).filter((value) => !/^(var\(--type-|inherit$|clamp\()/.test(value));
    expect(literal).toEqual([]);
  });

  it("never sets text below the macOS minimum", () => {
    expect(Number(tokens.match(/--type-micro:\s*(\d+)px/)?.[1])).toBeGreaterThanOrEqual(11);
  });

  it("uses three text weights, plus light for the home greeting", () => {
    const weights = new Set([...all.matchAll(/font-weight:\s*(\d+)/g)].map((match) => match[1]));
    for (const weight of weights) expect(["300", "400", "500", "600"]).toContain(weight);
  });
});
