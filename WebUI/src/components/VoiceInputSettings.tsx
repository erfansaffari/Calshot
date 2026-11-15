import { useEffect, useRef } from "react";
import { command, voiceLevels } from "../bridge";
import type { AppState } from "../types";
import { InlineError, Select } from "./ui";
import { useAction } from "../useAction";

function InputMeter({ active }: { active: boolean }) {
  const meter = useRef<HTMLDivElement>(null);
  const fill = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    let frame = 0;
    const draw = () => {
      const level = active ? Math.min(1, Math.max(0, voiceLevels.input)) : 0;
      if (fill.current) fill.current.style.transform = `scaleX(${level})`;
      meter.current?.setAttribute("aria-valuenow", String(Math.round(level * 100)));
      if (active) frame = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(frame);
  }, [active]);
  return <div ref={meter} className="microphone-meter" role="meter" aria-label="Microphone input level" aria-valuemin={0} aria-valuemax={100} aria-valuenow={0}><span ref={fill} /></div>;
}

export function VoiceInputSettings({ state }: { state: AppState }) {
  const input = state.voiceInput;
  const a = useAction();
  const latest = useRef(input); latest.current = input;
  useEffect(() => () => {
    const current = latest.current;
    if (current && ["checking", "testing"].includes(current.testState)) {
      void command({ action: "voiceInputStopTest", token: current.token }).catch(() => {});
    }
  }, []);
  if (!input) return null;
  const testing = input.testState === "checking" || input.testState === "testing";
  const locked = Boolean(state.voice?.active) || testing || a.busy;
  const configure = (uid: string) => void a.run("voiceInputConfigure", { token: input.token, uid });
  return <div className="voice-input-settings">
    <h3>Microphone</h3>
    <div className="settings-row"><span>Input device</span><Select label="Input device" value={input.selectedUID} disabled={locked} onChange={configure}>
      <option value="">System default</option>
      {!input.selectedAvailable && <option value={input.selectedUID}>Selected microphone (disconnected)</option>}
      {input.devices.map(device => <option key={device.uid} value={device.uid}>{device.name}</option>)}
    </Select></div>
    <p className="fine-print">Choose the Mac’s built-in microphone to avoid an unavailable phone or headset input. This changes Calshot only.</p>
    {input.devices.length === 0 && <p>No microphones found. Connect an input, then refresh the list.</p>}
    {!input.selectedAvailable && <p role="alert">The selected microphone is disconnected. Reconnect it or choose another input.</p>}
    <div className="voice-input-actions">
      <button className="button secondary" disabled={Boolean(state.voice?.active) || (!testing && (a.busy || !input.selectedAvailable || input.devices.length === 0))} onClick={() => void a.run(testing ? "voiceInputStopTest" : "voiceInputTest", { token: input.token })}>{testing ? "Stop microphone test" : "Test microphone"}</button>
      <button className="text-button" disabled={locked} onClick={() => void a.run("voiceInputRefresh", { token: input.token })}>Refresh microphones</button>
    </div>
    <InputMeter active={input.testState === "testing"} />
    <p role="status">{input.testState === "checking" ? "Requesting microphone access and starting input…" : input.testState === "testing" ? input.detectedSound ? "Sound detected. Keep speaking to check the level." : "Speak normally and watch the input level." : input.testState === "finished" ? input.detectedSound ? "Test finished. Calshot received sound from this microphone." : "Test finished without detecting sound. Choose another input and try again." : input.testState === "cancelled" ? "Microphone test stopped." : "Test for up to 15 seconds. Audio stays on this Mac; nothing is recorded or sent."}</p>
    {state.voice?.active && <p>Stop voice to change the input or run a microphone test.</p>}
    <InlineError message={a.error || input.error || undefined}>
      <button className="text-button" onClick={() => void a.run("voiceMicrophoneSettings", { token: state.voice?.token })}>Open microphone privacy settings</button>
      <button className="text-button" onClick={() => void a.run("voiceInputSettings", { token: state.voice?.token })}>Open Sound settings</button>
    </InlineError>
  </div>;
}
