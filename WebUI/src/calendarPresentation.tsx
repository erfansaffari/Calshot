import { createContext, useContext, useState, type ReactNode } from "react";

export const calendarColor = (index: number) =>
  `var(--calendar-${Math.max(0, index) % 6})`;
export const dateKey = (date: Date) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
export function monthDays(month: Date) {
  const start = new Date(month.getFullYear(), month.getMonth(), 1);
  const count = Math.ceil((start.getDay() + new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate()) / 7) * 7;
  start.setDate(start.getDate() - start.getDay());
  return Array.from(
    { length: count },
    (_, i) =>
      new Date(start.getFullYear(), start.getMonth(), start.getDate() + i),
  );
}
function useCalendarPresentation() {
  const [anchor, setAnchor] = useState(() => {
    const date = new Date();
    date.setHours(0, 0, 0, 0);
    return date;
  });
  const [mode, setMode] = useState<"day" | "week" | "month">("week");
  const [hidden, setHidden] = useState<Set<string>>(new Set());
  const toggleCalendar = (id: string) =>
    setHidden((old) => {
      const next = new Set(old);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  return { anchor, setAnchor, mode, setMode, hidden, toggleCalendar };
}
const CalendarContext = createContext<ReturnType<
  typeof useCalendarPresentation
> | null>(null);
export function CalendarPresentationProvider({
  children,
}: {
  children: ReactNode;
}) {
  const value = useCalendarPresentation();
  return (
    <CalendarContext.Provider value={value}>
      {children}
    </CalendarContext.Provider>
  );
}
export function useCalendar() {
  const value = useContext(CalendarContext);
  if (!value) throw new Error("Calendar presentation is unavailable.");
  return value;
}
