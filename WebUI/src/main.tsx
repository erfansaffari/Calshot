import { Component, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import NotchApp from "./NotchApp";
import "./styles.css";
import "./notch.css";
import { CalendarPresentationProvider } from "./calendarPresentation";
class ErrorBoundary extends Component<
  { children: ReactNode },
  { failed: boolean }
> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    return this.state.failed ? (
      <div className="empty" role="alert">
        <h2>Calshot's interface needs to reload</h2>
        <p>
          Completed calendar changes are kept. Reloading the interface does not
          repeat them.
        </p>
        <button
          className="button primary"
          onClick={() => window.location.reload()}
        >
          Reload interface
        </button>
      </div>
    ) : (
      this.props.children
    );
  }
}
createRoot(document.getElementById("root")!).render(
  <ErrorBoundary>
    {window.__calshotSurface === "notch" ||
    new URLSearchParams(location.search).get("surface") === "notch" ? (
      <NotchApp />
    ) : (
      <CalendarPresentationProvider>
        <App />
      </CalendarPresentationProvider>
    )}
  </ErrorBoundary>,
);
