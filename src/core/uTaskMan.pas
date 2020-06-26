unit uTaskMan;

{
  Sandcat Task Manager
  Copyright (c) 2011-2014, Syhunt Informatica
  License: 3-clause BSD license
  See https://github.com/felipedaragon/sandcat/ for details.
}

interface

uses
  Windows, Classes, Messages, Controls, SysUtils, Dialogs, ExtCtrls,
  Forms, TypInfo, Lua, LuaObject, uUIComponents, uRequests, CatMsgCromis;

type
  TSandcatTaskOnStop = procedure(const tid: string) of object;

type
  TSandcatTaskScripts = record
    OnClick: string;
    OnDoubleClick: string;
    OnParamChange: string;
    OnStop: string;
  end;

type
  TSandcatTask = class
  private
    fCaption: string;
    fDownloadFilename: string;
    fEnabled: boolean;
    fHasProgressBar: boolean;
    fHasMonitor: boolean;
    fHidden: boolean;
    fIcon: string;
    fIconStopped: string;
    fIsDownload: boolean;
    fLog: TStringList;
    fMenuHTML: string;
    fMonitor: TSandUIEngine;
    fMonitorQueue: TStringList;
    fMonitorQueueTimer: TTimer;
    fMsg: TCatMsgCromis;
    fOnStop: TSandcatTaskOnStop;
    fOriginatorTab: string;
    fParams: TSandJSON;
    fPID: integer;
    fProgressPos: integer;
    fProgressMax: integer;
    fScripts: TSandcatTaskScripts;
    fSuspended: boolean;
    fStatus: string;
    fStopped: boolean;
    fTabMsgHandle: HWND;
    fTag: string;
    fTID: string;
    function Format(const s: string): string;
    procedure MonitorEval(const tis: string);
    procedure QueueTIS(const s: string);
    procedure RemoveMonitor;
    procedure SetIcon(const url: string);
    procedure SetIconAni(const url: string);
    procedure SetCaption(const s: string);
    procedure SetStatus(const s: string);
    procedure SetMonitor(const m: TSandUIEngine);
    procedure SetTag(const s: string);
    procedure Suspend(const resume: boolean = false);
    procedure CopyDataMessage(const msg: integer; const str: string);
    procedure MonitorQueueTimerTimer(Sender: TObject);
    procedure TaskUpdated;
    procedure Write(const s: string);
    procedure WriteLn(const s: string);
  public
    function GetParam(const name, default: string): string;
    procedure DoSpecial(const s: string);
    procedure Finish(const reason: string = '');
    procedure GetInfoL(L: PLua_State);
    procedure RunScript(const s: string);
    procedure SetParam(const name, value: string);
    procedure SetParams(const json: string);
    procedure SetProgress(const pos: integer = 0; const max: integer = 100);
    procedure SetScript(const event, script: string);
    procedure Stop(const reason: string = ''; const quickstop: boolean = false);
    constructor Create(const tid: string);
    destructor Destroy; override;
    // properties
    property Caption: string read fCaption write SetCaption;
    property DownloadFilename: string read fDownloadFilename
      write fDownloadFilename;
    property Enabled: boolean read fEnabled;
    property Icon: string read fIcon write SetIcon;
    property IsDownload: boolean read fIsDownload;
    property IsSuspended: boolean read fSuspended;
    property msg: TCatMsgCromis read fMsg;
    property OnStop: TSandcatTaskOnStop read fOnStop write fOnStop;
    property Status: string read fStatus write SetStatus;
    property Tag: string read fTag write SetTag;
    property TID: string read fTID;
  end;

type
  TSandcatTaskManager = class
  private
    fCache: TSandObjCache;
    fRunning: boolean;
    fStartedTasks: integer;
    function CountActive: integer;
    function TaskExists(const tid: string): boolean;
    procedure KillActiveTasks;
    procedure ShutDown;
    procedure TaskStopped(const tid: string);
  public
    function AddTask(const MenuHTML: string; const Hidden: boolean = false)
      : TSandcatTask;
    function SelectTask(const tid: string; IsTag:boolean=false): TSandcatTask;
    procedure ClearInactiveTasks;
    procedure GetDownloadList(var sl: TStringList);
    procedure GetTaskList(var sl: TStringList);
    procedure RemoveTask(const tid: string);
    procedure RunJSONCmd(const json: string);
    procedure SetTaskParam_JSON(const json: string);
    procedure StopTask(const tid: string);
    procedure SuspendResumeTask(const tid: string);
    procedure SuspendTask(const tid: string; const resume: boolean = false);
    constructor Create(AOwner: TWinControl);
    destructor Destroy; override;
    property Running: boolean read fRunning write fRunning;
  end;

type
  TSandcatDownload = TSandcatTask;

type
  TSandcatDownloadManager = class
  private
    fDownloads: TSandJINI;
  public
    function Add(did: integer; fullpath: string): TSandcatDownload;
    function Get(did: integer): TSandcatDownload;
    procedure CancelList(list: TStringList);
    procedure Delete(did: integer);
    procedure HandleUpdate(list: TStringList; var cancel: boolean;
      const id, state, percentcomplete: integer; const fullpath: string);
    procedure RemoveDownloadFromList(list: TStringList; const id: string);
    procedure SetDownloadFilename(did: integer; suggestedname: string);
    constructor Create(AOwner: TWinControl);
    destructor Destroy; override;
  end;

const
  SCTASK_WRITELN = 1;
  SCTASK_LOGREQUEST_DYNAMIC = 2;

implementation

uses uMain, uZones, uTab, uMisc, LAPI_Task, CatHTTP, CatUI, pLua, pLuaTable,
  uConst, CatTime, CatStrings, CatTasks, CatChromium, CatChromiumLib;

var
  tasks_shutdown: boolean = false;

procedure Debug(const s: string; const component: string = 'Taskman');
begin
  uMain.Debug(s, component);
end;

{procedure SendAMessage(desthandle, msgid: integer; msgstr: string);
var
  pData: PCopyDataStruct;
begin
  pData := nil;
  try
    New(pData);
    pData^.dwData := msgid;
    pData^.cbData := Length(msgstr) + 1;
    pData^.lpData := PAnsiChar(AnsiString(msgstr));
    SendMessage(desthandle, WM_COPYDATA, application.Handle, integer(pData));
  finally
    Dispose(pData);
  end;
end;}

type
  TJSONCmds = (cmd_setcaption, cmd_setprogress, cmd_setscript, cmd_setstatus,
    cmd_special, cmd_print, cmd_outputmsg, cmd_showmsg, cmd_stop, cmd_finish,
    cmd_settag, cmd_writeln, cmd_write);

procedure TSandcatTaskManager.RunJSONCmd(const json: string);
var
  j: TSandJSON;
  Task: TSandcatTask;
  cmd: string;
begin
  j := TSandJSON.Create(json);
  Task := tasks.SelectTask(j['tid']);
  cmd := lowercase(j['cmd']);
  if Task <> nil then
  begin
    case TJSONCmds(GetEnumValue(TypeInfo(TJSONCmds), 'cmd_' + cmd)) of
      cmd_outputmsg:
        BottomBar.TaskMsgs.AddMessage(j['s'], Task.fPID, j.sObject.I['i']);
      cmd_setcaption:
        Task.SetCaption(j['s']);
      cmd_setprogress:
        Task.SetProgress(j['p'], j['m']);
      cmd_setscript:
        Task.SetScript(j['e'], j['s']);
      cmd_setstatus:
        Task.SetStatus(j['s']);
      cmd_settag:
        Task.SetTag(j['s']);
      cmd_special:
        Task.DoSpecial(j['s']);
      cmd_print:
        Task.writeln(j['s']);
      cmd_showmsg:
        sanddlg.showmessage(j.GetValue('s', emptystr));
      cmd_stop:
        Task.Stop(j.GetValue('s', emptystr));
      cmd_finish:
        Task.Finish(j.GetValue('s', emptystr));
      cmd_writeln:
        Task.writeln(j['s']);
      cmd_write:
        Task.Write(j['s']);
    end;
  end;
  j.Free;
end;

procedure TSandcatTaskManager.SetTaskParam_JSON(const json: string);
var
  p: TSandJINI;
  Task: TSandcatTask;
begin
  p := TSandJINI.Create;
  p.Text := json;
  Task := SelectTask(p.values['TID']);
  if Task <> nil then
    Task.SetParam(p.values['Name'], base64decode(p.values['Value']));
  p.Free;
end;

function TSandcatTaskManager.CountActive: integer;
var
  c: integer;
  Task: TSandcatTask;
begin
  result := 0;
  for c := fCache.Count - 1 downto 0 do
  begin
    Task := TSandcatTask(fCache.ObjectAt(c));
    if Task <> nil then
    begin
      if Task.fEnabled then
        result := result + 1;
    end;
  end;
end;

procedure TSandcatTaskManager.TaskStopped(const tid: string);
begin
  if CountActive = 0 then
    Running := false
  else
    Running := true;
  if Running = false then
    navbar.AnimateTasksIcon(false);
end;

procedure TSandcatTaskManager.GetTaskList(var sl: TStringList);
var
  c: integer;
  Task: TSandcatTask;
begin
  sl.clear;
  for c := fCache.Count - 1 downto 0 do
  begin
    Task := TSandcatTask(fCache.ObjectAt(c));
    if Task <> nil then
      sl.Add(Task.fTID);
  end;
end;

procedure TSandcatTaskManager.GetDownloadList(var sl: TStringList);
var
  c: integer;
  Task: TSandcatTask;
begin
  sl.clear;
  for c := fCache.Count - 1 downto 0 do
  begin
    Task := TSandcatTask(fCache.ObjectAt(c));
    if Task <> nil then
    begin
      if Task.fIsDownload then
        sl.Add(Task.fTID);
    end;
  end;
end;

function TSandcatTaskManager.TaskExists(const tid: string): boolean;
var
  c: integer;
  Task: TSandcatTask;
begin
  result := false;
  for c := fCache.Count - 1 downto 0 do
  begin
    Task := TSandcatTask(fCache.ObjectAt(c));
    if Task <> nil then
      if Task.fTID = tid then
        result := true;
  end;
end;

// Selects a task by its TID or by its tag name
function TSandcatTaskManager.SelectTask(const tid: string; IsTag:boolean=false): TSandcatTask;
var
  c: integer;
  Task: TSandcatTask;
begin
  result := nil;
  for c := fCache.Count - 1 downto 0 do
  begin
    Task := TSandcatTask(fCache.ObjectAt(c));
    if Task <> nil then begin
      if istag = false then begin
        if Task.fTID = tid then
          result := Task;
      end else begin
        if (Task.fTag <> emptystr) and (Task.fTag = tid) then
          result := Task;
      end;
    end;
  end;
end;

procedure TSandcatTaskManager.StopTask(const tid: string);
var
  Task: TSandcatTask;
begin
  Task := SelectTask(tid);
  if Task <> nil then
    Task.Stop;
end;

procedure TSandcatTaskManager.SuspendResumeTask(const tid: string);
var
  Task: TSandcatTask;
begin
  Task := SelectTask(tid);
  if Task = nil then
    exit;
  Task.Suspend(Task.IsSuspended);
end;

procedure TSandcatTaskManager.SuspendTask(const tid: string;
  const resume: boolean = false);
var
  Task: TSandcatTask;
begin
  Task := SelectTask(tid);
  if Task = nil then
    exit;
  Task.Suspend(resume);
end;

procedure TSandcatTaskManager.RemoveTask(const tid: string);
var
  Task: TSandcatTask;
begin
  Task := SelectTask(tid);
  if Task = nil then
    exit;
  Task.Stop(emptystr, true);
  Task.MonitorEval('Tasks.Remove("' + tid + '")');
  fCache.Remove(Task);
end;

function TSandcatTaskManager.AddTask(const MenuHTML: string;
  const Hidden: boolean = false): TSandcatTask;
const
  basic_menu = '<li .stop onclick="browser.stoptask([[%t]])">Stop</li>' + crlf +
    '<li .suspend onclick="browser.suspendtask([[%t]])">Suspend/Resume</li>' +
    crlf + '<li .remove onclick="browser.removetask([[%t]])">Remove</li>' + crlf
    + '<hr/>' + crlf
    + '<li onclick="browser.cleartasks()">Clear Tasks</li>';
var
  Task: TSandcatTask;
  taskid, menu: string;
  tab: TSandcatTab;
  j: TSandJSON;
  function myformat(s: string): string;
  begin
    result := replacestr(s, '%t', taskid);
  end;

begin
  result := nil;
  menu := MenuHTML;
  fStartedTasks := fStartedTasks + 1;
  taskid := inttostr(DateTimeToUnix(Now)) + '-' + inttostr(fStartedTasks);
  if TaskExists(taskid) then
    exit;
  Running := true;
  if menu <> emptystr then
    menu := menu + '<hr/>' + myformat(basic_menu)
  else
    menu := myformat(basic_menu);
  Task := TSandcatTask.Create(taskid);
  fCache.Add(Task);
  navbar.AnimateTasksIcon(true);
  Task.OnStop := TaskStopped;
  Task.fMenuHTML := myformat(menu);
  Task.fHidden := Hidden;
  result := Task;
  if Hidden = false then
  begin
    tab := tabmanager.ActiveTab;
    if tab <> nil then
    begin
      Task.fOriginatorTab := tab.UID;
      Task.fTabMsgHandle := tab.msg.msgHandle;
      contentarea.ToolsBar.ShowTaskMonitor;
      Task.SetMonitor(contentarea.toolsbar.TaskMonitor);
      // Associates the task monitor with this task
      j := TSandJSON.Create;
      j['tid'] := taskid;
      j['menu'] := Task.fMenuHTML;
      Task.fMonitor.eval('Tasks.Add(' + j.TextUnquoted + ')');
      j.Free;
      Task.SetIconAni('@ICON_RUNNING');
      Task.SetCaption('Starting Task...');
    end;
  end;
end;

procedure TSandcatTaskManager.ClearInactiveTasks;
var
  c: integer;
  Task: TSandcatTask;
begin
  Debug('clear.inactivetasks.begin');
  for c := fCache.Count - 1 downto 0 do
  begin
    Task := TSandcatTask(fCache.ObjectAt(c));
    if Task <> nil then
    begin
      if Task.Enabled = false then
        RemoveTask(Task.tid);
    end;
  end;
  Debug('clear.inactivetasks.end');
end;

procedure TSandcatTaskManager.KillActiveTasks;
var
  c: integer;
  Task: TSandcatTask;
begin
  Debug('kill.activetasks.begin');
  for c := fCache.Count - 1 downto 0 do
  begin
    Task := TSandcatTask(fCache.ObjectAt(c));
    if Task <> nil then
    begin
      Task.Stop(emptystr, true);
      if Task.fPID <> 0 then
      begin
        KillProcessByPID(Task.fPID);
        Task.fPID := 0;
      end;
    end;
  end;
  Debug('kill.activetasks.end');
end;

constructor TSandcatTaskManager.Create(AOwner: TWinControl);
begin
  inherited Create;
  fStartedTasks := 0;
  Running := false;
  fCache := TSandObjCache.Create(1000, true);
end;

procedure TSandcatTaskManager.ShutDown;
begin
  Debug('shutdown');
  tasks_shutdown := true;
  KillActiveTasks;
end;

destructor TSandcatTaskManager.Destroy;
begin
  tasks.ShutDown;
  inherited;
end;

// Sandcat Download Manager ****************************************************
procedure TSandcatDownloadManager.SetDownloadFilename(did: integer;
  suggestedname: string);
begin
  fDownloads.writestring(inttostr(did), 'file', suggestedname);
end;

procedure TSandcatDownloadManager.Delete(did: integer);
begin
  try
    fDownloads.DeleteSection(inttostr(did));
  except
  end;
end;

function TSandcatDownloadManager.Add(did: integer; fullpath: string)
  : TSandcatDownload;
var
  Task: TSandcatDownload;
begin
  Task := tasks.AddTask(emptystr);
  Task.fIsDownload := true;
  fDownloads.writestring(inttostr(did), 'tid', Task.fTID);
  Task.SetCaption(fDownloads.readstring(inttostr(did), 'file', emptystr));
  result := Task;
end;

function TSandcatDownloadManager.Get(did: integer): TSandcatDownload;
begin
  result := tasks.SelectTask(fDownloads.readstring(inttostr(did), 'tid',
    emptystr));
end;

// Cancels any active downloads that are in a list of download IDs
procedure TSandcatDownloadManager.CancelList(list: TStringList);
var
  slp: TSandSLParser;
  d: TSandcatDownload;
begin
  slp := TSandSLParser.Create(list);
  while slp.Found do
  begin
    d := Get(strtoint(slp.current));
    if d <> nil then
    begin
      d.Stop;
      RemoveDownloadFromList(list, slp.current);
    end;
  end;
  slp.Free;
end;

procedure TSandcatDownloadManager.HandleUpdate(list: TStringList;
  var cancel: boolean; const id, state, percentcomplete: integer;
  const fullpath: string);
var
  d: TSandcatDownload;
begin
  d := Get(id);
  if d = nil then
  begin // Task not found, creates it
    if state = SCD_INPROGRESS then
    begin
      if list.IndexOf(inttostr(id)) = -1 then
        list.Add(inttostr(id));
      d := Add(id, fullpath);
      bottombar.SetActivePage('tasks');
    end;
  end;
  if d = nil then
    exit;
  if d.Enabled = false then
    cancel := true; // Download cancelled by the user
  case state of
    SCD_INPROGRESS:
      begin
        if percentcomplete <= 100 then
        begin
          d.SetProgress(percentcomplete);
          d.Status := 'Downloading (' + inttostr(percentcomplete) + '%)...';
        end;
      end;
    SCD_COMPLETE:
      begin
        d.SetProgress(100);
        d.Stop('Download Complete.');
        d.Icon := ICON_CHECKED;
        if fullpath <> emptystr then
        begin
          d.SetScript('ondblclick', 'Sandcat.Downloader:launch(ctk.base64.decode[[' +
            base64encode(fullpath) + ']])');
          d.DownloadFilename := fullpath;
        end;
        RemoveDownloadFromList(list, inttostr(id));
      end;
    SCD_CANCELED:
      begin
        if percentcomplete <= 100 then
          d.SetProgress(percentcomplete);
        d.Stop;
        RemoveDownloadFromList(list, inttostr(id));
      end;
  end;
end;

// Removes a download from a list of downloads by its ID
procedure TSandcatDownloadManager.RemoveDownloadFromList(list: TStringList;
  const id: string);
begin
  if list.IndexOf(id) <> -1 then
  begin
    list.Delete(list.IndexOf(id));
    Delete(strtoint(id));
  end;
end;

constructor TSandcatDownloadManager.Create(AOwner: TWinControl);
begin
  inherited Create;
  fDownloads := TSandJINI.Create;
end;

destructor TSandcatDownloadManager.Destroy;
begin
  fDownloads.Free;
  inherited;
end;

// Sandcat Task ****************************************************************
procedure TSandcatTask.CopyDataMessage(const msg: integer; const str: string);
begin
  case (msg) of
    SCTASK_WRITELN:
      WriteLn(str);
    SCTASK_LOGREQUEST_DYNAMIC:
      SendCromisMessage(fTabMsgHandle, SCBM_LOGDYNAMICREQUEST, str);
  end;
end;

procedure TSandcatTask.GetInfoL(L: PLua_State);
var
  progress_desc, progress_icon: string;
  function getprog: string;
  begin
    result := inttostr(getpercentage(fProgressPos, fProgressMax)) + '%';
  end;

begin
  lua_newtable(L);
  plua_SetFieldValue(L, 'caption', fCaption);
  plua_SetFieldValue(L, 'menuhtml', fMenuHTML);
  if fIcon = emptystr then
  begin
    if fIsDownload then
      fIcon := ICON_DOWNLOADS
    else
      fIcon := ICON_LUA;
  end;
  plua_SetFieldValue(L, 'icon', fIcon);
  plua_SetFieldValue(L, 'enabled', fEnabled);
  plua_SetFieldValue(L, 'filename', fDownloadFilename);
  plua_SetFieldValue(L, 'status', fStatus);
  plua_SetFieldValue(L, 'onclick', fScripts.OnClick);
  plua_SetFieldValue(L, 'ondblclick', fScripts.OnDoubleClick);
  if fEnabled then
  begin
    progress_icon := ICON_TASK_RUNNING;
    if fHasProgressBar then
      progress_desc := getprog()
    else
      progress_desc := 'Running';
  end
  else
  begin
    if fStopped then
      progress_icon := ICON_BLANK
    else
      progress_icon := ICON_CHECKED;
    if fHasProgressBar then
      progress_desc := 'Done (' + getprog() + ').'
    else
      progress_desc := 'Done.';
  end;
  plua_SetFieldValue(L, 'progressicon', progress_icon);
  plua_SetFieldValue(L, 'progressdesc', progress_desc);
  plua_SetFieldValue(L, 'pid', fPID);
end;

procedure TSandcatTask.TaskUpdated;
begin
  if fScripts.OnParamChange <> emptystr then
    SendCromisMessage(fTabMsgHandle, SCBM_LUA_RUN, fScripts.OnParamChange);
end;

function TSandcatTask.GetParam(const name, default: string): string;
begin
  if fParams.HasPath(name) then
    result := fParams[name]
  else
    result := default;
end;

procedure TSandcatTask.SetParams(const json: string);
begin
  fParams.Text := json;
  TaskUpdated;
end;

procedure TSandcatTask.SetParam(const name, value: string);
begin
  // debug(tid+': Param '+params[name]+' set');
  fParams[name] := value;
  TaskUpdated;
end;

procedure TSandcatTask.RunScript(const s: string);
var
  processid: cardinal;
  e: ISandUIElement;
begin
  processid := RunTaskSeparateProcess(fTID, s,
    tabmanager.ActiveTab.msg.msgHandle, fParams);
  self.fPID := processid;
  if fHasMonitor then
  begin
    e := fMonitor.Root.Select('code.pid[tid="' + fTID + '"]');
    e.value := 'PID ' + inttostr(fPID);
  end;
end;

procedure TSandcatTask.SetStatus(const s: string);
var
  e: ISandUIElement;
  ns: string;
begin
  ns := s;
  ns := strmaxlen(ns, 200, true);
  fStatus := ns;
  if fHasMonitor then
  begin
    e := fMonitor.Root.Select('code.stat[tid="' + fTID + '"]');
    e.value := ns;
  end;
end;

procedure TSandcatTask.DoSpecial(const s: string);
var
  e: ISandUIElement;
  cMainDiv: string;
  procedure setfontcolor(color: string);
  begin
    e := fMonitor.Root.Select('code.pid[tid="' + fTID + '"]');
    e.StyleAttr['color'] := color;
    e := fMonitor.Root.Select('code.stat[tid="' + fTID + '"]');
    e.StyleAttr['color'] := color;
    e := fMonitor.Root.Select('table.log[tid="' + fTID + '"]');
    e.StyleAttr['color'] := color;
  end;

begin
  if fHasMonitor = false then
    exit;
  cMainDiv := 'div[tid="' + fTID + '"]';
  if s = 'paintred' then
  begin
    e := fMonitor.Root.Select(cMainDiv);
    e.StyleAttr['background-color'] := '#d55935 #b33515 #a12200 #8c0000';
    e.StyleAttr['border-color'] := '#e98c72 #d67860 #c66654 #b75548';
    e.StyleAttr['color'] := 'white';
    setfontcolor('white');
    SetIconAni('@ICON_BLANK');
    fIconStopped := '@ICON_FAILURE';
  end else
  if s = 'paintyellow' then
  begin
    e := fMonitor.Root.Select(cMainDiv);
    e.StyleAttr['background-color'] := '#c9bc15 #b5a512 #998500 #8d7a00';
    e.StyleAttr['border-color'] := '#f9f591 #eeea7e #c7ba13 #b5a50a';
    //orange:
    //e.StyleAttr['background-color'] := '#f8ca2d #edb218 #da9104 #cd7c04';
    //e.StyleAttr['border-color'] := '#ffdd39 #ffdb19 #ffd800 #ffd801';
    e.StyleAttr['color'] := 'white';
    setfontcolor('white');
    SetIconAni('@ICON_BLANK');
    fIconStopped := '@ICON_FATALERROR';
  end else
  if s = 'paintgreen' then
  begin
    e := fMonitor.Root.Select(cMainDiv);
    e.StyleAttr['background-color'] := '#59d535 #35b315 #22a100 #008c00';
    e.StyleAttr['border-color'] := '#8ce972 #78d660 #66c654 #55b748';
    e.StyleAttr['color'] := 'white';
    setfontcolor('white');
    SetIconAni('@ICON_BLANK');
    fIconStopped := '@ICON_SUCCESS';
  end;
end;

procedure TSandcatTask.SetScript(const event, script: string);
var
  e: ISandUIElement;
  ev, s: string;
begin
  ev := lowercase(event);
  s := Format(script);
  if ev = 'onparamchange' then
    fScripts.OnParamChange := s;
  if ev = 'onstop' then
    fScripts.OnStop := s;
  if fHasMonitor then
  begin
    if ev = 'onclick' then
    begin
      fScripts.OnClick := s;
      e := fMonitor.Root.Select('div[tid="' + fTID + '"]');
      if e <> nil then
        e.Attr[ev] := s;
    end;
    if ev = 'ondblclick' then
    begin
      fScripts.OnDoubleClick := s;
      e := fMonitor.Root.Select('div[tid="' + fTID + '"]');
      if e <> nil then
        e.Attr[ev] := s;
    end;
  end;
end;

procedure TSandcatTask.RemoveMonitor;
begin
  fHasMonitor := false;
  fHasProgressBar := false;
  fMonitor := nil;
end;

procedure TSandcatTask.SetMonitor(const m: TSandUIEngine);
begin
  fMonitor := m;
  fHasMonitor := true;
end;

procedure TSandcatTask.SetCaption(const s: string);
var
  e: ISandUIElement;
begin
  fCaption := strmaxlen(s, 100, true);
  if fHasMonitor then
  begin
    e := fMonitor.Root.Select('code.caption[tid="' + fTID + '"]');
    if e <> nil then
      e.value := fCaption;
  end;
end;

// ToDo, future: support multiple tags
procedure TSandcatTask.SetTag(const s: string);
begin
  fTag := s;
end;

procedure TSandcatTask.SetIconAni(const url: string);
var
  e: ISandUIElement;
begin
  if fHasMonitor = false then
  exit;
    e := fMonitor.Root.Select('img.staticon[tid="' + fTID + '"]');
    if e <> nil then
      e.StyleAttr['foreground-image'] := url;
end;

procedure TSandcatTask.SetIcon(const url: string);
begin
  fIcon := url;
end;

procedure TSandcatTask.SetProgress(const pos: integer = 0;
  const max: integer = 100);
var
  e: ISandUIElement;
begin
  fHasProgressBar := true;
  fProgressPos := pos;
  fProgressMax := max;
  // debug('settings progress:'+inttostr(pos)+' : '+inttostr(max));
  if fHasMonitor then
  begin
    e := fMonitor.Root.Select('div.dprog[tid="' + fTID + '"]');
    e.StyleAttr['display'] := 'block';
    e := fMonitor.Root.Select('progress.prog[tid="' + fTID + '"]');
    if e <> nil then
    begin
      e.value := integer(getpercentage(pos, max));
    end;
  end;
end;

procedure TSandcatTask.MonitorQueueTimerTimer(Sender: TObject);
begin
  if fMonitorQueue.Text = emptystr then
    exit;
  MonitorEval(fMonitorQueue.Text);
  fMonitorQueue.clear;
end;

procedure TSandcatTask.MonitorEval(const tis: string);
begin
  if fHasMonitor then
    SendCromisMessage(fTabMsgHandle, SCBM_MONITOR_EVAL, tis);
end;

procedure TSandcatTask.QueueTIS(const s: string);
begin
  fMonitorQueue.Add(s);
  // resets the timer count
  fMonitorQueueTimer.Enabled := false;
  fMonitorQueueTimer.Enabled := true;
end;

procedure TSandcatTask.Write(const s: string);
begin
  fLog.Text := fLog.Text + s;
end;

procedure TSandcatTask.writeln(const s: string);
var
  j: TSandJSON;
begin
  fLog.Add(s);
  j := TSandJSON.Create;
  j['ln'] := s;
  QueueTIS('Tasks.Print("' + fTID + '",' + j.TextUnquoted + ');');
  j.Free;
end;

procedure TSandcatTask.Suspend(const resume: boolean = false);
begin
  if fPID <> 0 then
  begin
    if resume = false then
    begin
      fSuspended := true;
      SuspendProcess(fPID);
      SetIconAni('@ICON_SUSPENDED');
      SetStatus('Suspended.');
      SendCromisMessage(fTabMsgHandle, SCBM_TASK_SUSPENDED, '1');
    end
    else
    begin
      fSuspended := false;
      ResumeProcess(fPID);
      SetIconAni('@ICON_RUNNING');
      SetStatus('Resumed.');
      SendCromisMessage(fTabMsgHandle, SCBM_TASK_RESUMED, '1');
    end;
  end;
end;

procedure TSandcatTask.Finish(const reason: string = '');
begin
  fScripts.OnStop := emptystr;
  Stop(reason, false);
end;

procedure TSandcatTask.Stop(const reason: string = '';
  const quickstop: boolean = false);
var
  e: ISandUIElement;
begin
  if fEnabled = false then
    exit; // Already stoped
  fEnabled := false;
  fScripts.OnParamChange := emptystr; // Clears the Lua code
  if fPID <> 0 then
  begin
    KillProcessByPID(fPID);
    fPID := 0;
  end;
  if fScripts.OnStop <> emptystr then
    extensions.RunLua(fScripts.OnStop);
  if quickstop then
    exit;
  if Assigned(OnStop) then
    OnStop(fTID);
  if reason = emptystr then
  begin
    SendCromisMessage(fTabMsgHandle, SCBM_TASK_STOPPED, '1');
    SetStatus('Stopped.');
    fStopped := true;
  end
  else
  begin
    SetStatus(reason);
  end;
  if fHasMonitor then
  begin
    e := fMonitor.Root.Select('menu#' + fTID + '-menu > li.stop');
    if e <> nil then
      e.Attr['disabled'] := 'disabled';
    e := fMonitor.Root.Select('menu#' + fTID + '-menu > li.suspend');
    if e <> nil then
      e.Attr['disabled'] := 'disabled';
    e := fMonitor.Root.Select('img.stop[tid="' + fTID + '"]');
    if e <> nil then
      e.StyleAttr['display'] := 'none';
    e := fMonitor.Root.Select('img.staticon[tid="' + fTID + '"]');
    if e <> nil then
      e.StyleAttr['foreground-image'] := fIconStopped;
    e := fMonitor.Root.Select('code.pid[tid="' + fTID + '"]');
    if e <> nil then
      e.StyleAttr['color'] := 'gray';
  end;
end;

function TSandcatTask.Format(const s: string): string;
begin
  result := replacestr(s, '%t', fTID);
end;

constructor TSandcatTask.Create(const tid: string);
begin
  inherited Create;
  self.fTID := tid;
  fMsg := TCatMsgCromis.Create;
  fMsg.OnDataMessage := CopyDataMessage;
  Debug('task created (handle ' + inttostr(fMsg.msgHandle) + ')');
  fEnabled := true;
  fStopped := false;
  fIsDownload := false;
  fHidden := false;
  fSuspended := false;
  fHasMonitor := false;
  fHasProgressBar := false;
  fProgressMax := 100;
  fIconStopped := '@ICON_BLANK';
  fParams := TSandJSON.Create;
  fLog := TStringList.Create;
  fMonitorQueue := TStringList.Create;
  fMonitorQueueTimer := TTimer.Create(SandBrowser);
  fMonitorQueueTimer.Interval := 500;
  fMonitorQueueTimer.OnTimer := MonitorQueueTimerTimer;
end;

destructor TSandcatTask.Destroy;
begin
  RemoveMonitor;
  fMonitorQueueTimer.Enabled := false;
  fMonitorQueueTimer.OnTimer := nil;
  fMonitorQueueTimer.Free;
  fMonitorQueue.Free;
  fLog.Free;
  fParams.Free;
  fMsg.Free;
  inherited;
end;

end.
