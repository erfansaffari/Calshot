import { useEffect, useRef, type RefObject } from "react";

/** Horizontal trackpad scrolling is one navigation per gesture, including its
 * momentum tail. Vertical/diagonal scrolling stays with the calendar scroller.
 * DOM wheel events don't expose AppKit's gesture phase, so a quiet gap ends it.
 */
export function useCalendarSwipe(
  ref: RefObject<HTMLElement | null>,
  navigate: (offset: number) => void,
  enabled = true,
) {
  const callback = useRef(navigate);
  useEffect(() => {
    callback.current = navigate;
  }, [navigate]);
  useEffect(() => {
    const element = ref.current;
    if (!element || !enabled) return;
    let last = -Infinity,
      x = 0,
      y = 0,
      direction: "horizontal" | "vertical" | undefined,
      navigated = false;
    const wheel = (event: WheelEvent) => {
      if (
        event.ctrlKey ||
        event.metaKey ||
        event.altKey ||
        document.querySelector('[role="dialog"]')
      )
        return;
      const now = performance.now();
      if (now - last > 200) {
        x = 0;
        y = 0;
        direction = undefined;
        navigated = false;
      }
      last = now;
      const scale =
        event.deltaMode === 1
          ? 16
          : event.deltaMode === 2
            ? element.clientWidth
            : 1;
      x += event.deltaX * scale;
      y += event.deltaY * scale;
      if (!direction && Math.max(Math.abs(x), Math.abs(y)) >= 12) {
        if (Math.abs(x) > Math.abs(y) * 1.5) direction = "horizontal";
        else if (Math.abs(y) > Math.abs(x) * 1.5) direction = "vertical";
      }
      if (direction !== "horizontal") return;
      event.preventDefault();
      if (!navigated && Math.abs(x) >= 70) {
        navigated = true;
        callback.current(x > 0 ? 1 : -1);
      }
    };
    element.addEventListener("wheel", wheel, { passive: false });
    return () => element.removeEventListener("wheel", wheel);
  }, [ref, enabled]);
}
