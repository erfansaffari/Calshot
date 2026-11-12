import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor, fireEvent } from "@testing-library/react";
import { UpNext, upcomingEvents, upcomingTasks } from "../src/components/UpNext";
import { preview } from "../src/preview";
import type { AppState, CalendarEvent, CalshotTask } from "../src/types";
import { command } from "../src/bridge";
import { CalendarPresentationProvider } from "../src/calendarPresentation";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined) }));
const now = new Date(2026,10,6,12);
const event = (id: string, offset = 1): CalendarEvent => ({ eventIdentifier:id,calendarIdentifier:"personal",title:`Fictional meeting ${id}`,start:new Date(2026,10,6+offset,14).toISOString(),end:new Date(2026,10,6+offset,15).toISOString(),isAllDay:false,calendarName:"Personal",sourceName:"Fixture" });
const task = (id:string, extra:Partial<CalshotTask>={}):CalshotTask => ({id,title:`Fictional task ${id}`,version:"v1",timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,notes:"",completed:false,deleted:false,rank:0,...extra});
function state(extra:Partial<AppState>={}):AppState {
 const start=new Date(2026,10,6),end=new Date(2026,10,13);
 return {...preview,page:"chat",calendarContentToken:"current",calendars:[{...preview.calendars[0],id:"personal"}],calendarView:{loaded:true,loading:false,start:start.toISOString().replace(".000Z","Z"),end:end.toISOString().replace(".000Z","Z"),contentToken:"current",events:[event("one")],errors:[]},tasks:{items:[],loaded:true,busy:false,token:"tasks",deviceID:"fixture"},...extra};
}
beforeEach(()=>{vi.useFakeTimers({toFake:["Date"]});vi.setSystemTime(now);vi.mocked(command).mockReset().mockResolvedValue(undefined);});
afterEach(()=>{cleanup();vi.useRealTimers();sessionStorage.clear();});
it("excludes finished and duplicate events and sorts same-day timed events before all-day reminders",()=>{
 const timed=event("one"),allDay={...event("all"),isAllDay:true,start:new Date(2026,10,7).toISOString()},ended=event("past",-1);
 expect(upcomingEvents([allDay,timed,timed,ended],now).map(e=>e.eventIdentifier)).toEqual(["one","all"]);
});
it("prioritizes open deadlines, excludes archived/completed and distant tasks, and keeps undated work last",()=>{
 expect(upcomingTasks([task("undated"),task("later",{dueDate:"2026-12-01"}),task("done",{completed:true}),task("archived",{deleted:true}),task("due",{dueDate:"2026-11-07"}),task("late",{dueDate:"2026-11-05"})],now).map(t=>t.id)).toEqual(["due","late","undated"]);
});
it("accepts native ISO timestamps without fractional seconds and opens the existing calendar route",async()=>{
 const onAction=vi.fn().mockResolvedValue(undefined);render(<CalendarPresentationProvider><UpNext state={state()} onAction={onAction}/></CalendarPresentationProvider>);
 const row=await screen.findByRole("button",{name:/Fictional meeting one/});fireEvent.click(row);
 expect(onAction).toHaveBeenCalledWith("navigate",{page:"calendars"});
 expect(command).toHaveBeenCalledWith(expect.objectContaining({action:"loadCalendarEvents",calendarIDs:["personal"]}));
});
it("reports incomplete searches without claiming an empty agenda",async()=>{
 const s=state();s.calendarView={...s.calendarView!,events:[],errors:[{calendarIdentifier:"personal",calendarName:"Personal",message:"Reconnect this source."}]};
 render(<UpNext state={s} onAction={vi.fn()}/>);
 await waitFor(()=>expect(screen.getByText("Some calendars couldn’t be checked")).toBeTruthy());
 expect(screen.queryByText("No upcoming events in the next 7 days.")).toBeNull();
});
it("keeps read failures local and provides a working retry",async()=>{
 vi.mocked(command).mockRejectedValueOnce(new Error("Connection unavailable."));
 render(<UpNext state={state()} onAction={vi.fn()}/>);
 expect((await screen.findByRole("alert")).textContent).toContain("Connection unavailable");
 fireEvent.click(screen.getByRole("button",{name:"Refresh upcoming events"}));
 await waitFor(()=>expect(command).toHaveBeenCalledTimes(2));
});
it("keeps the last events on screen while a native content-token change refreshes them",async()=>{
 const s=state(),view=render(<UpNext state={{...s,calendarContentToken:"new"}} onAction={vi.fn()}/>);
 await waitFor(()=>expect(command).toHaveBeenCalledTimes(1));
 expect(await screen.findByText("Fictional meeting one")).toBeTruthy();
 expect(screen.queryByText(/Checking your calendars/)).toBeNull();
 view.rerender(<UpNext state={{...s,calendarContentToken:"newer"}} onAction={vi.fn()}/>);
 await waitFor(()=>expect(command).toHaveBeenCalledTimes(2));
});
it("opens an overdue task through the existing task-editor handoff and never completes it",async()=>{
 const onAction=vi.fn().mockResolvedValue(undefined),s=state();s.tasks!.items=[task("task-id",{dueDate:"2026-11-05"})];
 render(<UpNext state={s} onAction={onAction}/>);
 fireEvent.click(screen.getByRole("button",{name:/Fictional task task-id/}));
 expect(sessionStorage.getItem("calshot.openTask")).toBe("task-id");
 expect(onAction).toHaveBeenCalledWith("navigate",{page:"tasks"});
 expect(command).not.toHaveBeenCalledWith(expect.objectContaining({action:"completeTask"}));
});

it("does not reload Tasks when opening a task from the current Tasks page",()=>{
 const onAction=vi.fn(),s=state();s.page="tasks";s.tasks!.items=[task("current")];
 render(<UpNext state={s} onAction={onAction}/>);
 fireEvent.click(screen.getByRole("button",{name:/Fictional task current/}));
 expect(sessionStorage.getItem("calshot.openTask")).toBe("current");
 expect(onAction).not.toHaveBeenCalled();
});
