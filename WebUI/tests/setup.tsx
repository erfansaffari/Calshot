import { createElement, Fragment, type ReactNode } from "react";
import { vi } from "vitest";
// The voice glow and orb are decorative canvas/SVG effects that jsdom cannot draw; tests check the text status instead.
vi.mock("voice-glow", () => ({ VoiceBeam: ({ children }: { children: ReactNode }) => createElement(Fragment, null, children) }));
vi.mock("thinking-orbs", () => ({ ThinkingOrb: (props: Record<string, unknown>) => createElement("span", { "data-orb": props.state, "aria-hidden": "true" }) }));
