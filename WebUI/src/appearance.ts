import { useLayoutEffect } from "react";
import type { AppState, GlassAppearance } from "./types";

export const defaultGlass: GlassAppearance = { enabled: true, opacity: 0.35, blur: 24, contrast: 0.5 };

/** Snapshots own saved appearance. Form drafts preview only inside the settings card. */
export function useGlassAppearance(state: AppState) {
  const glass = state.settings.glass ?? defaultGlass;
  const accessibility = state.displayAccessibility;
  useLayoutEffect(() => {
    const root = document.documentElement;
    root.dataset.glass = glass.enabled ? "on" : "off";
    root.dataset.reducedTransparency = String(accessibility?.reducedTransparency === true);
    root.dataset.increasedContrast = String(accessibility?.increasedContrast === true);
    root.style.setProperty("--glass-opacity", String(glass.opacity));
    root.style.setProperty("--glass-blur", `${glass.blur}px`);
    root.style.setProperty("--glass-contrast", String(glass.contrast));
  }, [glass.enabled, glass.opacity, glass.blur, glass.contrast, accessibility?.reducedTransparency, accessibility?.increasedContrast]);
}
