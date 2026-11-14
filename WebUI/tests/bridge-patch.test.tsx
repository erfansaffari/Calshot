import { act, renderHook } from "@testing-library/react";
import { expect, it } from "vitest";
import { useAppState, voiceLevels } from "../src/bridge";
import type { AppState } from "../src/types";

it("merges native patches so unchanged parts keep their identity", () => {
  const { result } = renderHook(() => useAppState());
  const messages = [{ role: "user", content: "Fictional question" }];
  act(() => window.__calshotPatch!({ ready: true, status: "Idle", messages, notice: "Fictional notice" } as Partial<AppState>, [], true));
  expect(result.current.status).toBe("Idle");
  const before = result.current.messages;

  act(() => window.__calshotPatch!({ status: "Working" }, ["notice"], false));
  expect(result.current.status).toBe("Working");
  expect(result.current.messages).toBe(before);
  expect("notice" in result.current).toBe(false);

  // A full snapshot replaces everything, as after a reload.
  act(() => window.__calshotPatch!({ ready: true, status: "Fresh" } as Partial<AppState>, [], true));
  expect(result.current.messages).toBeUndefined();
});

it("keeps voice levels out of app state", () => {
  window.__calshotLevels!(0.4, 0.1);
  expect(voiceLevels).toEqual({ input: 0.4, output: 0.1 });
});
