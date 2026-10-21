import { useRef, type ReactNode } from "react";
import { Check, ChevronDown, LoaderCircle, X, AlertCircle } from "lucide-react";
import * as Dialog from "@radix-ui/react-dialog";
export function Badge({
  children,
  tone = "neutral",
}: {
  children: ReactNode;
  tone?: string;
}) {
  return <span className={"badge " + tone}>{children}</span>;
}
export function Spinner() {
  return <LoaderCircle size={15} className="spin" aria-hidden />;
}
export function Empty({
  icon,
  title,
  children,
  action,
}: {
  icon: ReactNode;
  title: string;
  children: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty-icon">{icon}</div>
      <h2>{title}</h2>
      <p>{children}</p>
      {action}
    </div>
  );
}
export function Modal({
  title,
  children,
  onClose,
  wide = false,
  className = "",
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
  wide?: boolean;
  className?: string;
}) {
  const previousFocus = useRef(document.activeElement as HTMLElement | null);
  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="modal-backdrop" />
        <Dialog.Content
          onCloseAutoFocus={(event) => {
            event.preventDefault();
            if (previousFocus.current?.isConnected)
              previousFocus.current.focus();
          }}
          aria-describedby={undefined}
          className={"modal " + (wide ? "wide " : "") + className}
        >
          <header>
            <Dialog.Title>{title}</Dialog.Title>
            <Dialog.Close className="icon-button" aria-label="Close dialog">
              <X size={18} />
            </Dialog.Close>
          </header>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
export function Select({
  value,
  onChange,
  children,
  label,
  disabled = false,
}: {
  value: string;
  onChange: (value: string) => void;
  children: ReactNode;
  label: string;
  disabled?: boolean;
}) {
  return (
    <span className="select-wrap">
      <select
        aria-label={label}
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
      >
        {children}
      </select>
      <ChevronDown size={14} />
    </span>
  );
}
export function CheckBox({
  checked,
  disabled,
  onChange,
  label,
}: {
  checked: boolean;
  disabled?: boolean;
  onChange: (value: boolean) => void;
  label: string;
}) {
  return (
    <label className={"check " + (disabled ? "disabled" : "")}>
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        aria-label={label}
      />
      <span>{checked && <Check size={11} strokeWidth={3} />}</span>
    </label>
  );
}
export function InlineError({
  message,
  children,
}: {
  message?: string;
  children?: ReactNode;
}) {
  if (!message) return null;
  return (
    <div className="inline-error" role="alert">
      <AlertCircle size={16} />
      <div>
        <p>{message}</p>
        {children}
      </div>
    </div>
  );
}
export function formatDate(
  value?: string,
  zone?: string,
  options?: Intl.DateTimeFormatOptions,
) {
  if (!value) return "Date to confirm";
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: zone || undefined,
      month: "short",
      day: "numeric",
      ...options,
    }).format(new Date(value));
  } catch {
    return "Date to confirm";
  }
}
export function timeRange(
  start?: string,
  end?: string,
  zone?: string,
  allDay = false,
) {
  if (allDay) return "All day";
  if (!start || !end) return "Time to confirm";
  return (
    formatDate(start, zone, {
      month: undefined,
      day: undefined,
      hour: "numeric",
      minute: "2-digit",
    }) +
    " – " +
    formatDate(end, zone, {
      month: undefined,
      day: undefined,
      hour: "numeric",
      minute: "2-digit",
    })
  );
}
