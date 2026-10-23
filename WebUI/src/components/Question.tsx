import { useState } from "react";
import { MessageCircle, ArrowRight } from "lucide-react";
import type { AppState } from "../types";
import { command } from "../bridge";
import { Badge, InlineError, Spinner } from "./ui";
export function Question({
  question,
}: {
  question: NonNullable<AppState["question"]>;
}) {
  const [answer, setAnswer] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const submit = async (value?: string) => {
    setBusy(true);
    setError("");
    try {
      await command({
        action: value ? "answer" : "cancelQuestion",
        questionID: question.id,
        answer: value,
      });
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  };
  return (
    <section className="card question-card" aria-label="Question from Calshot">
      <Badge>
        <MessageCircle size={11} />
        Question
      </Badge>
      <h2>{question.question}</h2>
      {!!question.choices.length && (
        <div className="choices">
          {question.choices.slice(0, 6).map((choice, i) => (
            <button
              className="choice"
              key={i}
              disabled={busy}
              onClick={() => void submit(choice)}
            >
              <span>{choice}</span>
              <ArrowRight size={14} />
            </button>
          ))}
        </div>
      )}
      <form
        className="question-answer"
        onSubmit={(e) => {
          e.preventDefault();
          if (answer.trim()) void submit(answer.trim());
        }}
      >
        <input
          aria-label="Your answer"
          placeholder={
            question.choices.length
              ? "Or type a different answer…"
              : "Type your answer…"
          }
          value={answer}
          maxLength={8000}
          onChange={(e) => setAnswer(e.target.value)}
          disabled={busy}
        />
        <button className="button primary" disabled={!answer.trim() || busy}>
          {busy ? <Spinner /> : "Send"}
        </button>
      </form>
      <InlineError message={error} />
      <footer>
        <small>Calendar changes need your review.</small>
        <button
          className="text-button"
          disabled={busy}
          onClick={() => void submit()}
        >
          Cancel
        </button>
      </footer>
    </section>
  );
}
