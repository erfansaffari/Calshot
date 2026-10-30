import {afterEach,describe,expect,it,vi} from 'vitest';
import {cleanup,render,screen,fireEvent,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {Question} from '../src/components/Question';
import {Review} from '../src/components/Review';
import {preview} from '../src/preview';
import type {AppState} from '../src/types';
vi.mock('../src/bridge',()=>({command:vi.fn().mockResolvedValue(undefined)}));
import {command} from '../src/bridge';
afterEach(cleanup);
describe('Interactive calendar reviews',()=>{
 it('reviews undated imported tasks with the current native approval token',async()=>{
  const state=structuredClone(preview);state.proposals=[];state.calendars=[];state.selectedCalendarID='';state.canApprove=true;
  state.taskImport={id:'import-a',selectedInboxIDs:['task-a'],items:[{id:'task-a',version:'v1',title:'Read chapter',timeZone:'America/Toronto',notes:'',completed:false,deleted:false,rank:0,updatedAt:'2026-10-22T00:00:00Z',sourceText:'Reading list'}]};
  render(<Review state={state}/>);
  expect(screen.getByText('Inbox task · no calendar event')).toBeTruthy();
  await userEvent.click(screen.getByRole('button',{name:'Add 1 selected tasks'}));
  expect(command).toHaveBeenLastCalledWith({action:'approve',token:state.approvalToken});
 });

 it('binds long question choices and cancellation to the exact question',async()=>{
  const choices=Array.from({length:6},(_,i)=>'Class '+i+' — School / Shared family calendar — Thursday afternoon, long descriptive label');
  const view=render(<Question question={{id:'question-a',question:'Which class should move?',choices}}/>);
  await userEvent.click(screen.getByRole('button',{name:choices[4]}));
  expect(command).toHaveBeenCalledWith({action:'answer',questionID:'question-a',answer:choices[4]});
  view.unmount();render(<Question question={{id:'question-b',question:'Choose another class',choices:[]}}/>);
  await userEvent.click(screen.getByRole('button',{name:'Cancel'}));
  expect(command).toHaveBeenLastCalledWith({action:'cancelQuestion',questionID:'question-b',answer:undefined});
 });
 it('preserves a failed answer and shows the error next to the question',async()=>{
  vi.mocked(command).mockRejectedValueOnce(new Error('This question is no longer waiting.'));
  render(<Question question={{id:'question-c',question:'What time?',choices:[]}}/>);
  await userEvent.type(screen.getByRole('textbox',{name:'Your answer'}),'10:30 AM');
  await userEvent.click(screen.getByRole('button',{name:'Send'}));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent','This question is no longer waiting.');
  expect((screen.getByRole('textbox',{name:'Your answer'}) as HTMLInputElement).value).toBe('10:30 AM');
 });
 it('keeps deletes unchecked and sends the current review token',async()=>{
  const state=structuredClone(preview);const row=state.proposals[0];row.operation='delete';row.isSelected=false;row.targetCalendarName='Personal';state.proposals=[row];state.selectedCount=0;state.canApprove=false;
  render(<Review state={state}/>);
  const checkbox=screen.getByRole('checkbox',{name:'Include '+row.draft.title}) as HTMLInputElement;
  expect(checkbox.checked).toBe(false);
  await userEvent.click(checkbox);
  expect(command).toHaveBeenLastCalledWith({action:'selectProposal',token:state.approvalToken,proposalID:row.id,selected:true});
 });
 it('excludes completed receipts from a retry and keeps the partial-transfer explanation',async()=>{
  const state=structuredClone(preview);const [done,failed]=state.proposals;done.isFinished=true;done.state='moved';done.status='Moved';failed.state='failed';failed.error='Original could not be removed';failed.moveCopyReceipt={eventIdentifier:'verified-copy'};state.selectedCount=1;
  render(<Review state={state}/>);
  expect(screen.getAllByRole('checkbox').length).toBe(1);
  expect(screen.getByRole('alert').textContent).toContain('Copy exists in the destination');
  await userEvent.click(screen.getByRole('button',{name:'Retry 1 failed'}));
  expect(command).toHaveBeenLastCalledWith({action:'approve',token:state.approvalToken});
 });
 it('shows a full twelve-event batch without turning an unresolved row into an approval',()=>{
  const state=structuredClone(preview);state.proposals=Array.from({length:12},(_,i)=>({...structuredClone(state.proposals[0]),id:'row-'+i,operation:'create',draft:{...structuredClone(state.proposals[0].draft),title:'Assignment '+i},isSelected:i<9,canSelect:i<9,issues:i>=9?['Confirm the year.']:[]}));state.selectedCount=9;
  render(<Review state={state}/>);
  expect(screen.getAllByRole('checkbox').length).toBe(12);
  expect((screen.getByRole('checkbox',{name:'Include Assignment 11'}) as HTMLInputElement).disabled).toBe(true);
  expect(screen.getByRole('button',{name:'Add 9 to Personal'})).toBeDefined();
 });
});

describe('Appearance settings',()=>{
 it('offers System, Light and Dark and sends the explicit choice',async()=>{
  const {SettingsPage}=await import('../src/views/Pages');
  render(<SettingsPage state={preview}/>);
  const select=screen.getByRole('combobox',{name:'Appearance'});
  expect((select as HTMLSelectElement).value).toBe('system');
  await userEvent.selectOptions(select,'dark');
  expect(command).toHaveBeenLastCalledWith({action:'appearance',mode:'dark'});
 });
});

it('confirms missing years using the current native review token without approving', async()=>{
 const state=structuredClone(preview);
 state.proposals[0].draft.ambiguities=['missingYear'];
 const view=render(<Review state={state}/>);
 const confirm=screen.getByRole('button',{name:'Confirm year'});
 expect((confirm as HTMLButtonElement).disabled).toBe(true);
 await userEvent.type(screen.getByRole('spinbutton',{name:'Year for unconfirmed events'}),'2026');
 await userEvent.click(confirm);
 expect(command).toHaveBeenLastCalledWith({action:'confirmProposalYears',token:state.approvalToken,year:2026});
 state.proposals[0].draft.ambiguities=[];
 view.rerender(<Review state={state}/>);
 expect(screen.queryByRole('button',{name:'Confirm year'})).toBeNull();
});
