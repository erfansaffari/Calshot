import { useRef, type HTMLAttributes } from "react";
import { Mic } from "lucide-react";
import { VoiceBeam, type VoiceBeamColorVariant } from "voice-glow";
import { ThinkingOrb, type OrbState } from "thinking-orbs";
import type { VoiceState } from "../types";

export type VoicePhase = "connecting" | "ready" | "listening" | "thinking" | "speaking" | "review";

export function voicePhase(voice: VoiceState): VoicePhase {
  if (voice.talking) return "listening";
  if (voice.state === "connecting" || voice.state === "checking") return "connecting";
  if (voice.state === "thinking") return "thinking";
  if (voice.state === "speaking") return "speaking";
  if (voice.state === "waitingForReview") return "review";
  return "ready";
}

// One colour per phase so the state reads at a glance: blue hears you, violet thinks, green speaks.
const LOOK: Record<VoicePhase, { orb?: OrbState; glow?: VoiceBeamColorVariant; label: string }> = {
  connecting: { orb: "connecting", label: "Connecting" },
  ready: { label: "" },
  listening: { orb: "listening", glow: "ocean", label: "Listening" },
  thinking: { orb: "breathing", glow: "candy", label: "Thinking" },
  speaking: { orb: "composing", glow: "forest", label: "Speaking" },
  review: { label: "Ready to approve" },
};

/**
 * Compact voice status for the notch. The glow follows the microphone while held and Calshot's voice while it
 * speaks; the text status stays the accessible source of truth (the glow and orb are decorative).
 */
export function VoicePill({ voice, talkProps, children }: {
  voice: VoiceState; talkProps: HTMLAttributes<HTMLButtonElement>; children?: React.ReactNode;
}) {
  const phase = voicePhase(voice), look = LOOK[phase];
  const level = useRef(0);
  level.current = phase === "speaking" ? voice.outputLevel ?? 0.4 : phase === "listening" ? voice.inputLevel : 0;
  const shortcut = voice.shortcut || "⌃⇧V";
  const label = look.label || `Hold ${shortcut} to talk`;
  const pill = (
    <div className={"voice-pill is-" + phase}>
      <button className="voice-talk" aria-label="Hold to talk" aria-pressed={Boolean(voice.talking)}
        title={`Hold to talk (${shortcut}). While held, the pointer draws on your screen.`} {...talkProps}>
        {look.orb ? <ThinkingOrb state={look.orb} size={64} theme="dark" aria-hidden="true" style={{ width: 26, height: 26 }} /> : <Mic size={16} />}
      </button>
      <span className="voice-pill-label" role="status">{label}</span>
      {children}
    </div>
  );
  if (!look.glow) return pill;
  // Thinking has no voice to follow: a slow breath keeps the violet glow alive without implying sound.
  const drive = phase === "thinking" ? () => 0.22 + 0.14 * Math.sin(performance.now() / 520) : () => level.current;
  return <VoiceBeam level={drive} colorVariant={look.glow} theme="dark">{pill}</VoiceBeam>;
}
