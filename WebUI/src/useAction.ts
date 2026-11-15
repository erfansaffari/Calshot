import { useState } from "react";
import { command } from "./bridge";
export function useAction() {
  const [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [notice, setNotice] = useState("");
  return {
    error,
    busy,
    notice,
    run: async (action: string, extra: Record<string, unknown> = {}) => {
      setBusy(true);
      setError("");
      setNotice("");
      try {
        await command({ action, ...extra });
        return true;
      } catch (e) {
        setError((e as Error).message);
        return false;
      } finally {
        setBusy(false);
      }
    },
    setNotice,
  };
}
