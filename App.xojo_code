#tag Class
Protected Class App
Inherits DesktopApplication
	#tag Event
		Sub Closing()
		  If mTray <> Nil Then
		    Self.RemoveTrayItem(mTray)
		  End If
		End Sub
	#tag EndEvent

	#tag Event
		Sub Opening()
		  ' No main window: the tray icon is the UI, the details window opens on demand.
		  AllowAutoQuit = False
		  mWinPorts = New Dictionary
		  mWslPorts = New Dictionary
		  mWslOwners = New Dictionary
		  mDockerPorts = New Dictionary
		  mContainers = New Dictionary
		  mHealth = New Dictionary
		  mHealthMsg = New Dictionary
		  mHealthDue = New Dictionary
		  mHealthConns = New Dictionary
		  mSeen = New Dictionary
		  mPortVerdict = New Dictionary
		  mAutoChecked = New Dictionary
		  mRunning = New Dictionary
		  mModelNames = New Dictionary
		  mLearnedOwner = New Dictionary
		  mRemote = New Dictionary
		  mRemoteConns = New Dictionary
		  mRemoteStarted = New Dictionary
		  mServerNames = New Dictionary

		  mTray = New TrayIcon
		  mTray.Icon = MakeIcon(kColorUnknown)
		  mTray.Tooltip = "ServiceTray: starting"
		  If Not Self.AddTrayItem(mTray) Then
		    MessageBox("ServiceTray could not add its tray icon.")
		    Quit
		  End If

		  LoadConfig

		  mWslShell = New Shell
		  mWslShell.ExecuteMode = Shell.ExecuteModes.Asynchronous
		  AddHandler mWslShell.Completed, WeakAddressOf WslCompleted

		  ' One cheap 1 s heartbeat; each source decides from its own interval whether it is due.
		  mTimer = New Timer
		  mTimer.Period = 1000
		  mTimer.RunMode = Timer.RunModes.Multiple
		  AddHandler mTimer.Action, WeakAddressOf Tick
		  RefreshNow

		  ' --details opens the window at start (handy as a second shortcut); --menu pops the
		  ' tray menu up at the mouse after a few seconds, for screenshots.
		  If System.CommandLine.IndexOf("--details") >= 0 Then ShowDetails
		  If System.CommandLine.IndexOf("--prefs") >= 0 Then DoAction("prefs")
		  If System.CommandLine.IndexOf("--menu") >= 0 Then Timer.CallLater(6000, AddressOf ShowMenu)
		  ' --check-ports runs the port check once the first probes are in; results land in status.txt.
		  If System.CommandLine.IndexOf("--check-ports") >= 0 Then Timer.CallLater(8000, AddressOf AutoCheckPorts)
		End Sub
	#tag EndEvent


	#tag Method, Flags = &h21
		Private Sub ActionCompleted(sender As Shell)
		  For i As Integer = mActionShells.LastIndex DownTo 0
		    If mActionShells(i) = sender Then mActionShells.RemoveAt(i)
		  Next
		  If sender.ExitCode <> 0 Then
		    MessageBox("Command failed (exit " + sender.ExitCode.ToString + "):" + EndOfLine + EndOfLine + sender.Result.Trim)
		  End If
		  ' Look again soon rather than waiting out the normal intervals.
		  mHealth = New Dictionary
		  mHealthDue = New Dictionary
		  ProbeWsl
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub AutoCheckPorts()
		  CheckPorts(False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub CheckPorts(interactive As Boolean)
		  ' Ports that should be free but cannot be bound. Two causes on this machine:
		  ' Windows' excluded ranges (Hyper-V/WinNAT leases, netsh shows them), and
		  ' mirrored-networking phantoms (Windows refuses, nothing lists a holder, WSL binds).
		  Var ports() As Integer
		  For Each s As Dictionary In mServices
		    Var p As Integer = GetInt(s, "port", 0)
		    If p > 1023 And ports.IndexOf(p) < 0 Then ports.Add(p)
		  Next
		  For Each p As Integer In mCheckPorts
		    If ports.IndexOf(p) < 0 Then ports.Add(p)
		  Next
		  ' A port somebody is listening on is taken for an honest reason; skip it.
		  For i As Integer = ports.LastIndex DownTo 0
		    If mWinPorts.HasKey(ports(i)) Or mWslPorts.HasKey(ports(i)) Then ports.RemoveAt(i)
		  Next
		  ports.Sort

		  Var ranges() As Pair = PortProbe.ExcludedRanges
		  Var winFail As New Dictionary
		  For Each p As Integer In ports
		    Var rc As Integer = PortProbe.WindowsBind(p)
		    If rc <> 0 Then winFail.Value(p) = rc
		  Next

		  ' WSL's view only matters for the ports Windows refused.
		  Var wslFail As New Dictionary
		  Var wslKnown As Boolean
		  If winFail.KeyCount > 0 And mWslRunning Then
		    Var args() As String
		    For Each k As Variant In winFail.Keys
		      args.Add(k.StringValue)
		    Next
		    Var sh As New Shell
		    sh.ExecuteMode = Shell.ExecuteModes.Synchronous
		    sh.Execute("wsl.exe -d " + mDistro + " -e python3 -c ""exec('import socket,sys\nh=sys.argv[1]\nfor p in sys.argv[2:]:\n s=socket.socket()\n try:\n  s.bind((h,int(p)));r=0\n except OSError as e:\n  r=e.errno\n s.close();print(p,r)')"" 127.0.0.1 " + String.FromArray(args, " "))
		    For Each line As String In sh.Result.ReplaceAll(EndOfLine.Windows, EndOfLine.UNIX).ToArray(EndOfLine.UNIX)
		      Var f() As String = Words(line)
		      If f.Count = 2 Then
		        wslKnown = True
		        If f(1) <> "0" Then wslFail.Value(f(0).ToInteger) = f(1).ToInteger
		      End If
		    Next
		  End If

		  If interactive Then mPortVerdict = New Dictionary
		  Var report() As String
		  For Each p As Integer In ports
		    If Not winFail.HasKey(p) Then
		      If mPortVerdict.HasKey(p) Then mPortVerdict.Remove(p)
		      Continue
		    End If
		    Var verdict As String
		    Var range As String
		    For Each r As Pair In ranges
		      If p >= r.Left.IntegerValue And p <= r.Right.IntegerValue Then range = r.Left.StringValue + "-" + r.Right.StringValue
		    Next
		    If range <> "" Then
		      verdict = "reserved by Windows (excluded range " + range + ")"
		    ElseIf wslKnown And Not wslFail.HasKey(p) Then
		      verdict = "phantom: Windows refuses, WSL binds, nobody listens"
		    ElseIf wslFail.HasKey(p) Then
		      verdict = "unbindable on both sides, no listener (error " + winFail.Value(p).StringValue + " / errno " + wslFail.Value(p).StringValue + ")"
		    Else
		      verdict = "Windows refuses it (error " + winFail.Value(p).StringValue + "), no listener"
		    End If
		    mPortVerdict.Value(p) = verdict
		    report.Add(":" + p.ToString + "   " + verdict)
		  Next
		  mPortCheckTime = DateTime.Now
		  mPortCheckCount = ports.Count
		  mLastStatus = ""
		  Refresh

		  If interactive Then
		    Var d As New MessageDialog
		    d.Title = "Port check"
		    If report.Count = 0 Then
		      d.Message = "All " + ports.Count.ToString + " idle ports are bindable."
		      d.Explanation = "Checked every configured port that nothing is listening on, plus checkPorts."
		    Else
		      d.Message = report.Count.ToString + " of " + ports.Count.ToString + " idle ports cannot be bound"
		      d.Explanation = String.FromArray(report, EndOfLine) + EndOfLine + EndOfLine + _
		      "Excluded range: pick another port, or claim it first with netsh int ipv4 add excludedportrange (elevated)." + EndOfLine + _
		      "Phantom: a dead WSL process leaked the mirrored reservation; wsl --shutdown clears it, or move the service."
		    End If
		    Call d.ShowModal
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ConfigFile() As FolderItem
		  Var dir As FolderItem = SpecialFolder.ApplicationData.Child("ServiceTray")
		  If Not dir.Exists Then dir.CreateFolder
		  Return dir.Child("services.json")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub DefaultAction(key As String)
		  ' Double-click in the details window: open whatever the row points at.
		  Var url As String
		  If key.BeginsWith("svc:") Then
		    Var s As Dictionary = ServiceByKey(key)
		    If s <> Nil Then url = GetStr(s, "open")
		  ElseIf key.BeginsWith("port:") Then
		    url = "http://localhost:" + Field(key, ":", 2) + "/"
		  End If
		  If url <> "" Then System.GotoURL(url)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub DetailsClosed()
		  mDetails = Nil
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function DetailRows() As Dictionary()
		  ' Everything the details window shows, as rows: kind, cells(), status, key.
		  ' Services come in the same order and sections as the tray menu.
		  Var rows() As Dictionary
		  For Each item As Dictionary In Layout
		    Select Case item.Value("kind").StringValue
		    Case "head"
		      Var members() As Dictionary = item.Value("members")
		      Var ok, total As Integer
		      Var worst As Integer = Rollup(members, ok, total)
		      rows.Add(Row("group", worst, "", item.Value("text").StringValue, ok.ToString + "/" + total.ToString + " ok", "", "", "", ""))
		    Case "sub"
		      rows.Add(Row("sub", kStUnknown, "", "  " + item.Value("text").StringValue, "", "", "", "", ""))
		    Case "svc"
		      Var sv As Dictionary = item.Value("svc")
		      Var detail As String
		      Var stt As Integer = Status(sv, detail)
		      Var port As Integer = GetInt(sv, "port", 0)
		      rows.Add(Row("service", stt, "svc:" + mServices.IndexOf(sv).ToString, _
		      "    " + GetStr(sv, "name"), StatusWord(stt), If(port > 0, port.ToString, ""), EnvName(sv), Owner(sv), detail))
		      If sv = LlamaService Then
		        For Each k As Variant In mRunning.Keys
		          rows.Add(Row("model", If(mRunning.Value(k).StringValue = "ready", kStUp, kStDegraded), "model:" + k.StringValue, _
		          "        " + ModelLabel(k.StringValue), mRunning.Value(k).StringValue, "", "GPU", "llama-swap", ""))
		        Next
		      End If
		    End Select
		  Next

		  Var eph() As String = PortKeys(True)
		  rows.Add(Row("group", kStUnknown, "", "Ephemeral", eph.Count.ToString + " new since start", "", "", "", ""))
		  For Each k As String In eph
		    rows.Add(Row("port", kStEphemeral, "port:" + k, "    " + PortOwner(k), "new", Field(k, ":", 1), SideName(Field(k, ":", 0)), PortOwner(k), "since " + SeenText(k)))
		  Next
		  Var other() As String = PortKeys(False)
		  rows.Add(Row("group", kStUnknown, "", "Other listeners", other.Count.ToString + " unlisted", "", "", "", ""))
		  For Each k As String In other
		    rows.Add(Row("port", kStIdle, "port:" + k, "    " + PortOwner(k), "listening", Field(k, ":", 1), SideName(Field(k, ":", 0)), PortOwner(k), "already up at start"))
		  Next

		  Var res() As Dictionary = ReservedServices
		  If res.Count > 0 Then
		    Var ok, total As Integer
		    Var worst As Integer = Rollup(res, ok, total)
		    rows.Add(Row("group", worst, "", "Reserved ports", ok.ToString + "/" + total.ToString + " ok", "", "", "", ""))
		    For Each sv As Dictionary In res
		      Var detail As String
		      Var stt As Integer = Status(sv, detail)
		      rows.Add(Row("service", stt, "svc:" + mServices.IndexOf(sv).ToString, _
		      "    " + GetStr(sv, "name"), StatusWord(stt), GetInt(sv, "port", 0).ToString, EnvName(sv), Owner(sv), detail))
		    Next
		  End If

		  If mPortCheckTime <> Nil Then
		    rows.Add(Row("group", kStUnknown, "", "Port check", mPortVerdict.KeyCount.ToString + " of " + mPortCheckCount.ToString + " unbindable", "", "", "", _
		    "at " + mPortCheckTime.ToString(Locale.Current, DateTime.FormatStyles.None, DateTime.FormatStyles.Short)))
		    For Each k As Variant In mPortVerdict.Keys
		      rows.Add(Row("check", kStDown, "", "    :" + k.StringValue, "unbindable", k.StringValue, "Windows", "", mPortVerdict.Value(k).StringValue))
		    Next
		  End If
		  Return rows
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub DoAction(tag As String)
		  If tag.BeginsWith("open:") Then
		    System.GotoURL(tag.Middle(5))
		  ElseIf tag.BeginsWith("copy:") Then
		    Var c As New Clipboard
		    c.Text = tag.Middle(5)
		    c.Close
		  ElseIf tag.BeginsWith("restart:") Then
		    Var s As Dictionary = ServiceByKey("svc:" + tag.Middle(8))
		    If s = Nil Then Return
		    Var d As New MessageDialog
		    d.Message = "Restart " + GetStr(s, "name") + "?"
		    d.Explanation = GetStr(s, "restart")
		    If s = LlamaService Then d.Explanation = "This kills every running model, including queued ComfyUI jobs." + EndOfLine + EndOfLine + d.Explanation
		    d.ActionButton.Caption = "Restart"
		    d.CancelButton.Visible = True
		    If d.ShowModal = d.ActionButton Then RunCommand(GetStr(s, "restart"))
		  ElseIf tag.BeginsWith("unload:") Then
		    LlamaRequest("POST", "/api/models/unload/" + tag.Middle(7), "unload")
		  ElseIf tag = "unloadall" Then
		    LlamaRequest("POST", "/api/models/unload", "unload all")
		  ElseIf tag.BeginsWith("load:") Then
		    ' llama-swap has no load endpoint; any request through /upstream/<model>/ starts it.
		    LlamaRequest("GET", "/upstream/" + tag.Middle(5) + "/", "load")
		  ElseIf tag = "refresh" Then
		    RefreshNow
		  ElseIf tag = "details" Then
		    ShowDetails
		  ElseIf tag = "prefs" Then
		    If mPrefs = Nil Then mPrefs = New PrefsWindow
		    mPrefs.Show
		  ElseIf tag = "checkports" Then
		    CheckPorts(True)
		  ElseIf tag = "edit" Then
		    ConfigFile.Open
		  ElseIf tag = "reload" Then
		    ReloadConfig
		  ElseIf tag.BeginsWith("adopt:") Then
		    ' "adopt:<service index>:<port>": the service was found listening elsewhere.
		    Var s As Dictionary = ServiceByKey("svc:" + Field(tag, ":", 1))
		    If s <> Nil Then Call SetServicePort(s, Field(tag, ":", 2).ToInteger)
		  ElseIf tag.BeginsWith("setport:") Then
		    Var s As Dictionary = ServiceByKey("svc:" + tag.Middle(8))
		    If s = Nil Then Return
		    Var w As New PortWindow
		    w.Prepare(GetStr(s, "name"), GetInt(s, "port", 0), MovedTo(s))
		    w.ShowModal
		    If w.Chosen > 0 And w.Chosen <> GetInt(s, "port", 0) Then Call SetServicePort(s, w.Chosen)
		  ElseIf tag = "quit" Then
		    Quit
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Field(s As String, delim As String, index As Integer) As String
		  Var parts() As String = s.ToArray(delim)
		  If index < 0 Or index > parts.LastIndex Then Return ""
		  Return parts(index)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub FillActions(key As String, into As DesktopMenuItem)
		  ' The per-row actions, shared by the tray submenus and the details window's context menu.
		  If key.BeginsWith("model:") Then
		    into.AddMenu(New DesktopMenuItem("Unload " + key.Middle(6), "unload:" + key.Middle(6)))
		    Return
		  End If
		  If key.BeginsWith("port:") Then
		    Var port As String = Field(key, ":", 2)
		    into.AddMenu(New DesktopMenuItem("Open http://localhost:" + port + "/", "open:http://localhost:" + port + "/"))
		    into.AddMenu(New DesktopMenuItem("Copy port", "copy:" + port))
		    Return
		  End If
		  Var s As Dictionary = ServiceByKey(key)
		  If s = Nil Then Return
		  If s = LlamaService Then
		    For Each k As Variant In mRunning.Keys
		      into.AddMenu(New DesktopMenuItem("Unload " + ModelLabel(k.StringValue) + "   [" + mRunning.Value(k).StringValue + "]", "unload:" + k.StringValue))
		    Next
		    If mRunning.KeyCount > 1 Then into.AddMenu(New DesktopMenuItem("Unload all", "unloadall"))
		    Var load As New DesktopMenuItem("Load")
		    For Each id As String In mModels
		      If Not mRunning.HasKey(id) Then load.AddMenu(New DesktopMenuItem(ModelLabel(id), "load:" + id))
		    Next
		    load.Enabled = mLlamaUp And load.Count > 0
		    into.AddMenu(load)
		    into.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  End If
		  Var url As String = GetStr(s, "open")
		  If url <> "" Then into.AddMenu(New DesktopMenuItem("Open " + url, "open:" + url))
		  If GetStr(s, "restart") <> "" Then into.AddMenu(New DesktopMenuItem(If(s = LlamaService, "Restart gateway...", "Restart..."), "restart:" + key.Middle(4)))
		  Var port As Integer = GetInt(s, "port", 0)
		  If port > 0 Then into.AddMenu(New DesktopMenuItem("Copy port", "copy:" + port.ToString))
		  If port > 0 And GetStr(s, "side") = "server" Then into.AddMenu(New DesktopMenuItem("Copy address", "copy:" + GetStr(s, "host") + ":" + port.ToString))
		  Var moved As Integer = MovedTo(s)
		  If moved > 0 Then into.AddMenu(New DesktopMenuItem("Use :" + moved.ToString + " (update services.json)", "adopt:" + key.Middle(4) + ":" + moved.ToString))
		  into.AddMenu(New DesktopMenuItem("Change port...", "setport:" + key.Middle(4)))
		  Var who As String = Owner(s)
		  If who <> "" Then
		    Var info As New DesktopMenuItem("Owner: " + who)
		    info.Enabled = False
		    into.AddMenu(info)
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function GetInt(d As Dictionary, key As String, def As Integer) As Integer
		  If d <> Nil And d.HasKey(key) Then Return d.Value(key).IntegerValue
		  Return def
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function GetStr(d As Dictionary, key As String) As String
		  If d <> Nil And d.HasKey(key) Then Return d.Value(key).StringValue
		  Return ""
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function GroupOf(s As Dictionary) As String
		  Var g As String = GetStr(s, "group")
		  If g <> "" Then Return g
		  Return EnvName(s)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Groups() As String()
		  ' In order of first appearance in services.json.
		  Var out() As String
		  For Each s As Dictionary In mServices
		    If out.IndexOf(GroupOf(s)) < 0 Then out.Add(GroupOf(s))
		  Next
		  Return out
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StartEvents()
		  ' One long-lived GET; llama-swap sends the full model list at once, then again on
		  ' every change (loading, ready, stopping). Timeout 0 = wait indefinitely.
		  mSseBuf = ""
		  mEventsAlive = False
		  mEventsStarted = mSeconds
		  mEventsConn = New URLConnection
		  AddHandler mEventsConn.ReceivingProgressed, WeakAddressOf EventsData
		  AddHandler mEventsConn.ContentReceived, WeakAddressOf EventsEnded
		  AddHandler mEventsConn.Error, WeakAddressOf EventsError
		  mEventsConn.Send("GET", mLlamaUrl + "/api/events", 0)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub EventsData(sender As URLConnection, bytesReceived As Int64, totalBytes As Int64, newData As String)
		  #Pragma Unused sender
		  #Pragma Unused bytesReceived
		  #Pragma Unused totalBytes
		  ' Server-sent events: blocks separated by a blank line, payload on "data:" lines.
		  ' Bytes are buffered raw so a UTF-8 character split across chunks survives.
		  mSseBuf = mSseBuf + newData
		  Var sep As String = Chr(10) + Chr(10)
		  Var cut As Integer = mSseBuf.IndexOfBytes(sep)
		  While cut >= 0
		    Var block As String = mSseBuf.LeftBytes(cut).DefineEncoding(Encodings.UTF8)
		    mSseBuf = mSseBuf.MiddleBytes(cut + 2)
		    For Each line As String In block.ToArray(Chr(10))
		      If line.BeginsWith("data:") Then HandleEvent(line.Middle(5).Trim)
		    Next
		    cut = mSseBuf.IndexOfBytes(sep)
		  Wend
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub EventsEnded(sender As URLConnection, URL As String, HTTPStatus As Integer, content As String)
		  #Pragma Unused sender
		  #Pragma Unused URL
		  #Pragma Unused HTTPStatus
		  #Pragma Unused content
		  ' The gateway closed the stream (restart, shutdown): reconnect shortly.
		  mEventsConn = Nil
		  mEventsRetryAt = mSeconds + 5
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub EventsError(sender As URLConnection, e As RuntimeException)
		  #Pragma Unused sender
		  #Pragma Unused e
		  mEventsConn = Nil
		  mEventsRetryAt = mSeconds + 5
		  mLlamaUp = False
		  mRunning = New Dictionary
		  mDirty = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub HandleEvent(json As String)
		  ' {"type":"modelStatus","data":"[{\"id\":…,\"state\":\"ready\",\"unlisted\":false}, …]"}
		  ' The data field is itself JSON, as a string. Other event types are ignored.
		  Try
		    Var ev As Dictionary = ParseJSON(json)
		    If GetStr(ev, "type") <> "modelStatus" Then Return
		    Var arr() As Variant = ParseJSON(GetStr(ev, "data"))
		    Var ids() As String
		    Var names As New Dictionary
		    Var running As New Dictionary
		    For Each v As Variant In arr
		      Var m As Dictionary = v
		      Var id As String = GetStr(m, "id")
		      Var stt As String = GetStr(m, "state")
		      If stt <> "stopped" And stt <> "shutdown" And stt <> "" Then running.Value(id) = stt
		      If m.HasKey("unlisted") And m.Value("unlisted").BooleanValue Then Continue
		      ids.Add(id)
		      names.Value(id) = If(GetStr(m, "name") <> "", GetStr(m, "name"), id)
		    Next
		    mModels = ids
		    mModelNames = names
		    ' A model that starts or stops changes VRAM: read it on the next tick.
		    If running.KeyCount <> mRunning.KeyCount Then mGpuDue = 0
		    mRunning = running
		    mLlamaUp = True
		    mEventsAlive = True
		    mDirty = True
		  Catch e As RuntimeException
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub GpuCompleted(sender As Shell)
		  ' nvidia-smi --format=csv,noheader,nounits -> "1832, 8192" (MiB)
		  Var parts() As String = sender.Result.Trim.ToArray(",")
		  If parts.Count >= 2 And parts(1).Trim.ToInteger > 0 Then
		    mVramUsed = parts(0).Trim.ToInteger
		    mVramTotal = parts(1).Trim.ToInteger
		    mDirty = True
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub HealthCheck(s As Dictionary)
		  Var c As New URLConnection
		  AddHandler c.ContentReceived, WeakAddressOf HealthReceived
		  AddHandler c.Error, WeakAddressOf HealthError
		  ' Held here so the request survives until it answers; the value says whose check it is.
		  mHealthConns.Value(c) = GetStr(s, "name")
		  ' Only the status matters. Plain bodies also avoid Brotli (Gramps Web sends it),
		  ' which URLConnection fails to decode.
		  c.RequestHeader("Accept-Encoding") = "identity"
		  c.Send("GET", GetStr(s, "health"), 5)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub HealthError(sender As URLConnection, e As RuntimeException)
		  If Not mHealthConns.HasKey(sender) Then Return
		  mHealth.Value(mHealthConns.Value(sender).StringValue) = 0
		  mHealthMsg.Value(mHealthConns.Value(sender).StringValue) = e.Message
		  mHealthConns.Remove(sender)
		  mDirty = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub HealthReceived(sender As URLConnection, URL As String, HTTPStatus As Integer, content As String)
		  #Pragma Unused URL
		  #Pragma Unused content
		  If Not mHealthConns.HasKey(sender) Then Return
		  mHealth.Value(mHealthConns.Value(sender).StringValue) = HTTPStatus
		  mHealthConns.Remove(sender)
		  mDirty = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsIgnored(port As Integer) As Boolean
		  If port >= mIgnoreFrom Then Return True
		  Return mIgnorePorts.IndexOf(port) >= 0
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function EnvName(s As Dictionary) As String
		  Select Case GetStr(s, "side")
		  Case "wsl"
		    Return "WSL"
		  Case "server"
		    Return HostName(s)
		  End Select
		  Return "Windows"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function HostLabel(s As Dictionary) As String
		  ' "borsippa  192.168.1.32", or just the address when servers{} does not name it.
		  Var host As String = GetStr(s, "host")
		  Var name As String = HostName(s)
		  Return If(name = host, host, name + "  " + host)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function HostName(s As Dictionary) As String
		  Var host As String = GetStr(s, "host")
		  Return mServerNames.Lookup(host, host).StringValue
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsReserved(s As Dictionary) As Boolean
		  Return s.HasKey("reserved") And s.Value("reserved").BooleanValue
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ProbeServers()
		  ' One TCP connect per distinct host:port of the "server" services; an open port is
		  ' all that is learned here, the health URL (if any) says the rest.
		  For Each s As Dictionary In mServices
		    If GetStr(s, "side") <> "server" Or GetInt(s, "port", 0) = 0 Then Continue
		    Var addr As String = GetStr(s, "host") + ":" + GetInt(s, "port", 0).ToString
		    If mRemoteStarted.HasKey(addr) Then Continue
		    Var t As New TCPSocket
		    t.Address = GetStr(s, "host")
		    t.Port = GetInt(s, "port", 0)
		    AddHandler t.Connected, WeakAddressOf RemoteConnected
		    AddHandler t.Error, WeakAddressOf RemoteError
		    ' Held here until it answers; the value says which address it is testing.
		    mRemoteConns.Value(t) = addr
		    mRemoteStarted.Value(addr) = System.Microseconds
		    t.Connect
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub RemoteConnected(sender As TCPSocket)
		  RemoteDone(sender, True)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub RemoteDone(sender As TCPSocket, open As Boolean)
		  If Not mRemoteConns.HasKey(sender) Then Return
		  Var addr As String = mRemoteConns.Value(sender)
		  mRemoteConns.Remove(sender)
		  If mRemoteStarted.HasKey(addr) Then mRemoteStarted.Remove(addr)
		  mRemote.Value(addr) = open
		  mDirty = True
		  ' Removed above first, so an Error raised by the disconnect is ignored.
		  Try
		    sender.Disconnect
		  Catch e As RuntimeException
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub RemoteError(sender As TCPSocket, e As RuntimeException)
		  #Pragma Unused e
		  RemoteDone(sender, False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ReservedServices() As Dictionary()
		  Var out() As Dictionary
		  For Each s As Dictionary In mServices
		    If IsReserved(s) Then out.Add(s)
		  Next
		  Return out
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsListed(port As Integer, side As String) As Boolean
		  For Each s As Dictionary In mServices
		    If GetInt(s, "port", 0) = port And GetStr(s, "side") = side Then Return True
		  Next
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LlamaActionDone(sender As URLConnection, URL As String, HTTPStatus As Integer, content As String)
		  #Pragma Unused URL
		  #Pragma Unused content
		  Var what As String = LlamaForget(sender)
		  ' /upstream/<model>/ answers with whatever the model server serves at its root,
		  ' which can be a 404 even though the load itself worked, so only unloads are checked.
		  If HTTPStatus >= 400 And what <> "load" Then
		    MessageBox("llama-swap answered HTTP " + HTTPStatus.ToString + " to " + what + ".")
		  End If
		  If mLlamaPolling Then PollLlama(False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LlamaActionError(sender As URLConnection, e As RuntimeException)
		  Var what As String = LlamaForget(sender)
		  MessageBox("Request to llama-swap (" + what + ") failed: " + e.Message)
		  If mLlamaPolling Then PollLlama(False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function LlamaForget(c As URLConnection) As String
		  Var what As String
		  For i As Integer = mActions.LastIndex DownTo 0
		    If mActions(i) = c Then
		      what = mActionWhat(i)
		      mActions.RemoveAt(i)
		      mActionWhat.RemoveAt(i)
		    End If
		  Next
		  Return what
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LlamaPollError(sender As URLConnection, e As RuntimeException)
		  #Pragma Unused sender
		  #Pragma Unused e
		  mLlamaUp = False
		  mRunning = New Dictionary
		  mDirty = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LlamaRequest(method As String, path As String, what As String)
		  Var c As New URLConnection
		  AddHandler c.ContentReceived, WeakAddressOf LlamaActionDone
		  AddHandler c.Error, WeakAddressOf LlamaActionError
		  ' Held in mActions so a long model load is not cancelled by garbage collection.
		  mActions.Add(c)
		  mActionWhat.Add(what)
		  c.Send(method, mLlamaUrl + path, 900)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function LlamaService() As Dictionary
		  If mLlamaUrl = "" Then Return Nil
		  For Each s As Dictionary In mServices
		    If GetStr(s, "name") = mLlamaName Then Return s
		  Next
		  Return Nil
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LoadConfig()
		  mServices.RemoveAll
		  mIgnorePorts.RemoveAll
		  mCheckPorts.RemoveAll
		  mConfigError = ""
		  mDistro = "Debian"
		  mWinEvery = 5
		  mWslEvery = 15
		  mHealthEvery = 30
		  mIgnoreFrom = 49152
		  mCollapseHealthy = False
		  mLlamaUrl = ""
		  mLlamaName = ""
		  mServerNames = New Dictionary
		  mServerTitle = "Server"
		  mRemoteEvery = 30

		  Var f As FolderItem = ConfigFile
		  If Not f.Exists Then
		    Var out As TextOutputStream = TextOutputStream.Create(f)
		    out.Write("{" + EndOfLine + "  ""services"": []" + EndOfLine + "}" + EndOfLine)
		    out.Close
		    mConfigError = "No services configured yet"
		    Return
		  End If

		  ' Remembered so an edit made outside the app (an editor, an agent) is picked up.
		  mConfigStamp = f.ModificationDateTime.SecondsFrom1970
		  Try
		    Var tin As TextInputStream = TextInputStream.Open(f)
		    Var d As Dictionary = ParseJSON(tin.ReadAll(Encodings.UTF8))
		    tin.Close
		    If d.HasKey("wslDistro") Then mDistro = d.Value("wslDistro").StringValue
		    mWinEvery = Max(1, GetInt(d, "windowsEvery", mWinEvery))
		    mWslEvery = Max(5, GetInt(d, "wslEvery", mWslEvery))
		    mHealthEvery = Max(5, GetInt(d, "healthEvery", mHealthEvery))
		    mIgnoreFrom = GetInt(d, "ignoreFrom", mIgnoreFrom)
		    mCollapseHealthy = d.HasKey("collapseHealthy") And d.Value("collapseHealthy").BooleanValue
		    If d.HasKey("ignorePorts") Then
		      Var ports() As Variant = d.Value("ignorePorts")
		      For Each p As Variant In ports
		        mIgnorePorts.Add(p.IntegerValue)
		      Next
		    End If
		    ' checkPorts: extra ports for the port check, as numbers or "from-to" strings.
		    If d.HasKey("checkPorts") Then
		      Var ports() As Variant = d.Value("checkPorts")
		      For Each p As Variant In ports
		        Var bits() As String = p.StringValue.ToArray("-")
		        Var lo As Integer = bits(0).Trim.ToInteger
		        Var hi As Integer = If(bits.Count > 1, bits(1).Trim.ToInteger, lo)
		        For n As Integer = lo To Min(hi, lo + 500)
		          If n > 0 And mCheckPorts.IndexOf(n) < 0 Then mCheckPorts.Add(n)
		        Next
		      Next
		    End If
		    ' servers: {"192.168.1.32": "borsippa", …} names the machines "side": "server" points at.
		    mRemoteEvery = Max(5, GetInt(d, "serverEvery", mRemoteEvery))
		    If GetStr(d, "serverTitle") <> "" Then mServerTitle = GetStr(d, "serverTitle")
		    If d.HasKey("servers") Then
		      Var sd As Dictionary = d.Value("servers")
		      For Each k As Variant In sd.Keys
		        mServerNames.Value(k.StringValue) = sd.Value(k).StringValue
		      Next
		    End If
		    If d.HasKey("llamaSwap") Then
		      Var ls As Dictionary = d.Value("llamaSwap")
		      mLlamaUrl = GetStr(ls, "url")
		      mLlamaName = GetStr(ls, "service")
		    End If
		    If d.HasKey("services") Then
		      Var arr() As Variant = d.Value("services")
		      For Each v As Variant In arr
		        Var s As Dictionary = v
		        If GetStr(s, "name") <> "" Then mServices.Add(s)
		      Next
		    End If
		  Catch e As RuntimeException
		    mConfigError = "services.json: " + e.Message
		  End Try
		  If mConfigError = "" And mServices.Count = 0 Then mConfigError = "No services configured yet"
		  LoadSettings
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Layout() As Dictionary()
		  ' The ordered list both views render: "head" (section, with its members), "sub"
		  ' (a quiet category label) and "svc" entries, per the Preferences sort.
		  Var shown() As Dictionary
		  For Each sv As Dictionary In mServices
		    If IsReserved(sv) Then Continue
		    Var port As Integer = GetInt(sv, "port", 0)
		    If mPortFrom > 0 And port > 0 And port < mPortFrom Then Continue
		    If mPortTo > 0 And port > mPortTo Then Continue
		    If mHideIdle Then
		      Var detail As String
		      If Status(sv, detail) = kStIdle Then Continue
		    End If
		    shown.Add(sv)
		  Next

		  Var out() As Dictionary
		  Select Case mSortBy
		  Case "category"
		    For Each g As String In Groups
		      Var members() As Dictionary
		      For Each sv As Dictionary In shown
		        If GroupOf(sv) = g Then members.Add(sv)
		      Next
		      AddSection(out, g, members, False)
		    Next
		  Case "port", "name"
		    Var keys() As String
		    Var members() As Dictionary
		    For Each sv As Dictionary In shown
		      If mSortBy = "port" Then
		        Var port As Integer = GetInt(sv, "port", 0)
		        keys.Add(Format(If(port = 0, 99999, port), "00000") + GetStr(sv, "name"))
		      Else
		        keys.Add(GetStr(sv, "name").Lowercase)
		      End If
		      members.Add(sv)
		    Next
		    keys.SortWith(members)
		    AddSection(out, If(mSortBy = "port", "By port", "By name"), members, False)
		  Else
		    ' Environment: Windows, then WSL, each with its categories as sub-labels, then the
		    ' server machines, labelled by host instead.
		    Var sides() As String = Array("win", "wsl", "server")
		    For Each side As String In sides
		      Var members() As Dictionary
		      For Each sv As Dictionary In shown
		        If GetStr(sv, "side") = side Then members.Add(sv)
		      Next
		      Var title As String = If(side = "win", "Windows", "WSL (" + mDistro + ")" + If(mWslKnown And Not mWslRunning, ": not running", ""))
		      If side = "server" Then title = mServerTitle
		      AddSection(out, title, members, mShowCategories Or side = "server", side = "server")
		    Next
		  End Select
		  Return out
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub AddSection(out() As Dictionary, title As String, members() As Dictionary, withCategories As Boolean, byHost As Boolean = False)
		  If members.Count = 0 Then Return
		  Var head As New Dictionary
		  head.Value("kind") = "head"
		  head.Value("text") = title
		  head.Value("members") = members
		  out.Add(head)
		  If Not withCategories Then
		    For Each sv As Dictionary In members
		      out.Add(MakeEntry("svc", "", sv))
		    Next
		    Return
		  End If
		  ' Categories (or hosts) in config order; a service without one sits at the top.
		  Var cats() As String
		  For Each sv As Dictionary In members
		    Var c As String = If(byHost, HostLabel(sv), GetStr(sv, "group"))
		    If cats.IndexOf(c) < 0 Then cats.Add(c)
		  Next
		  For Each c As String In cats
		    If c <> "" Then out.Add(MakeEntry("sub", c, Nil))
		    For Each sv As Dictionary In members
		      If If(byHost, HostLabel(sv), GetStr(sv, "group")) = c Then out.Add(MakeEntry("svc", "", sv))
		    Next
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function MakeEntry(kind As String, text As String, sv As Dictionary) As Dictionary
		  Var d As New Dictionary
		  d.Value("kind") = kind
		  d.Value("text") = text
		  d.Value("svc") = sv
		  Return d
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Rollup(members() As Dictionary, ByRef ok As Integer, ByRef total As Integer) As Integer
		  Var worst As Integer = kStUp
		  ok = 0
		  total = members.Count
		  For Each sv As Dictionary In members
		    Var detail As String
		    Var stt As Integer = Status(sv, detail)
		    If stt = kStUp Or stt = kStIdle Then ok = ok + 1
		    If Severity(stt) > Severity(worst) Then worst = stt
		  Next
		  Return worst
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function SideName(side As String) As String
		  Return If(side = "wsl", "WSL", "Windows")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function Setting(name As String) As Variant
		  ' Read by the Preferences window.
		  Select Case name
		  Case "sortBy"
		    Return mSortBy
		  Case "showCategories"
		    Return mShowCategories
		  Case "collapseHealthy"
		    Return mCollapseHealthy
		  Case "hideIdle"
		    Return mHideIdle
		  Case "portFrom"
		    Return mPortFrom
		  Case "portTo"
		    Return mPortTo
		  End Select
		  Return Nil
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ApplySettings(d As Dictionary)
		  ' Called by the Preferences window on every change: apply, redraw, persist.
		  mSortBy = GetStr(d, "sortBy")
		  If mSortBy = "" Then mSortBy = "environment"
		  mShowCategories = d.Lookup("showCategories", True).BooleanValue
		  mCollapseHealthy = d.Lookup("collapseHealthy", False).BooleanValue
		  mHideIdle = d.Lookup("hideIdle", False).BooleanValue
		  mPortFrom = GetInt(d, "portFrom", 0)
		  mPortTo = GetInt(d, "portTo", 0)
		  Try
		    Var out As TextOutputStream = TextOutputStream.Create(SettingsFile)
		    out.Write(GenerateJSON(d, True))
		    out.Close
		  Catch e As IOException
		  End Try
		  mLastStatus = ""
		  Refresh
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LoadSettings()
		  ' settings.json holds view preferences; services.json stays the list of services.
		  Var d As New Dictionary
		  Try
		    If SettingsFile.Exists Then
		      Var tin As TextInputStream = TextInputStream.Open(SettingsFile)
		      d = ParseJSON(tin.ReadAll(Encodings.UTF8))
		      tin.Close
		    End If
		  Catch e As RuntimeException
		  End Try
		  mSortBy = GetStr(d, "sortBy")
		  If mSortBy = "" Then mSortBy = "environment"
		  mShowCategories = d.Lookup("showCategories", True).BooleanValue
		  ' collapseHealthy used to live in services.json; that value still counts as the default.
		  mCollapseHealthy = d.Lookup("collapseHealthy", mCollapseHealthy).BooleanValue
		  mHideIdle = d.Lookup("hideIdle", False).BooleanValue
		  mPortFrom = GetInt(d, "portFrom", 0)
		  mPortTo = GetInt(d, "portTo", 0)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function SettingsFile() As FolderItem
		  Return ConfigFile.Parent.Child("settings.json")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub PrefsClosed()
		  mPrefs = Nil
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function MakeIcon(c As Color) As Picture
		  ' A disc in the colour of the worst service state; inside it, LlamaTray's white
		  ' VRAM bar when NVML answers, otherwise a plain white dot.
		  Var p As New Picture(32, 32)
		  Var g As Graphics = p.Graphics
		  g.AntiAliased = True
		  g.DrawingColor = c
		  g.FillOval(1, 1, 30, 30)
		  g.DrawingColor = &cFFFFFF00
		  If mVramTotal > 0 Then
		    Var h As Integer = Round(22 * Min(1.0, mVramUsed / mVramTotal))
		    g.DrawRectangle(12, 5, 8, 22)
		    g.FillRectangle(12, 27 - h, 8, h)
		  Else
		    g.FillOval(11, 11, 10, 10)
		  End If
		  Return p
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Dot(st As Integer, big As Boolean = False) As Picture
		  ' A coloured status dot for the menu's icon gutter, the column Windows keeps for
		  ' checkmarks. Drawn at 1x, 1.5x and 2x so it stays sharp on scaled displays.
		  If mDots = Nil Then mDots = New Dictionary
		  Var key As String = st.ToString + If(big, "b", "")
		  If mDots.HasKey(key) Then Return mDots.Value(key)
		  Var c As Color = &c7F8C8D00
		  Select Case st
		  Case kStUp
		    c = &c27AE6000
		  Case kStDegraded
		    c = &cE67E2200
		  Case kStDown
		    c = &cC0392B00
		  Case kStEphemeral
		    c = &c2E86DE00
		  End Select
		  Var reps() As Picture
		  For Each scale As Double In Array(1.0, 1.5, 2.0)
		    Var px As Integer = Round(16 * scale)
		    Var p As New Picture(px, px)
		    Var g As Graphics = p.Graphics
		    g.AntiAliased = True
		    g.DrawingColor = c
		    Var d As Double = If(big, 12, 9) * scale
		    If st = kStIdle Then
		      ' Idle stays hollow, like the old ○.
		      g.PenSize = Max(1, Round(1.5 * scale))
		      g.DrawOval((px - d) / 2, (px - d) / 2, d, d)
		    Else
		      g.FillOval((px - d) / 2, (px - d) / 2, d, d)
		    End If
		    p.HorizontalResolution = 72 * scale
		    p.VerticalResolution = 72 * scale
		    reps.Add(p)
		  Next
		  Var pic As New Picture(16, 16, reps)
		  mDots.Value(key) = pic
		  Return pic
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function Mark(st As Integer) As String
		  Select Case st
		  Case kStUp
		    Return "✓"
		  Case kStIdle
		    Return "○"
		  Case kStDegraded
		    Return "!"
		  Case kStDown
		    Return "✗"
		  Case kStEphemeral
		    Return "●"
		  End Select
		  Return "…"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function MenuLine(name As String, st As Integer, port As Integer, detail As String) As String
		  ' The status is the item's icon (see Dot), so the text starts at the gutter. After
		  ' the tab Windows right-aligns the port, so ports line up.
		  #Pragma Unused st
		  Var left As String = name.Trim
		  If detail <> "" Then left = left + "  -  " + detail
		  If port > 0 Then Return left + Chr(9) + ":" + port.ToString
		  Return left
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ModelLabel(id As String) As String
		  If mModelNames.HasKey(id) Then
		    Var name As String = mModelNames.Value(id)
		    If name <> "" And name <> id Then Return name + "  (" + id + ")"
		  End If
		  Return id
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ModelsReceived(sender As URLConnection, URL As String, HTTPStatus As Integer, content As String)
		  #Pragma Unused sender
		  #Pragma Unused URL
		  If HTTPStatus <> 200 Then Return
		  ' Keep real models only; aliases (ipa, whisper, ollama tags...) would flood the menu.
		  Var ids() As String
		  Var names As New Dictionary
		  Try
		    Var d As Dictionary = ParseJSON(content)
		    Var arr() As Variant = d.Value("data")
		    For Each v As Variant In arr
		      Var m As Dictionary = v
		      Var kind As String = "model"
		      If m.HasKey("meta") Then
		        Var meta As Dictionary = m.Value("meta")
		        If meta.HasKey("llamaswap") Then
		          Var ls As Dictionary = meta.Value("llamaswap")
		          If ls.HasKey("type") Then kind = ls.Value("type").StringValue
		        End If
		      End If
		      If kind = "model" Then
		        Var id As String = m.Value("id").StringValue
		        ids.Add(id)
		        names.Value(id) = If(m.HasKey("name"), m.Value("name").StringValue, id)
		      End If
		    Next
		  Catch e As RuntimeException
		    Return
		  End Try
		  mModels = ids
		  mModelNames = names
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Owner(s As Dictionary) As String
		  Var port As Integer = GetInt(s, "port", 0)
		  If GetStr(s, "side") = "server" Then Return HostLabel(s)
		  If GetStr(s, "side") = "wsl" Then
		    If GetStr(s, "docker") <> "" And mContainers.HasKey(GetStr(s, "docker")) Then
		      Return "docker " + GetStr(s, "docker") + " (" + mContainers.Value(GetStr(s, "docker")).StringValue + ")"
		    End If
		    If mWslOwners.HasKey(port) Then Return mWslOwners.Value(port)
		    Return ""
		  End If
		  If mWinPorts.HasKey(port) Then Return mWinPorts.Value(port)
		  Return ""
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub PollLlama(withModels As Boolean)
		  If mLlamaUrl = "" Then Return
		  mLlamaConn = New URLConnection
		  AddHandler mLlamaConn.ContentReceived, WeakAddressOf RunningReceived
		  AddHandler mLlamaConn.Error, WeakAddressOf LlamaPollError
		  mLlamaConn.Send("GET", mLlamaUrl + "/running", 3)
		  ' The model list rarely changes (config edits), so it is fetched far less often.
		  If withModels Or mModels.Count = 0 Then
		    mModelsConn = New URLConnection
		    AddHandler mModelsConn.ContentReceived, WeakAddressOf ModelsReceived
		    mModelsConn.Send("GET", mLlamaUrl + "/v1/models", 5)
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function PortKeys(ephemeral As Boolean) As String()
		  ' Unlisted listeners as "side:port", sorted by port. Ephemeral ones appeared after
		  ' ServiceTray had taken its first look; the rest were already there.
		  Var keys() As String
		  Var nums() As Integer
		  For Each k As Variant In mSeen.Keys
		    Var isNew As Boolean = mSeen.Value(k) <> Nil
		    If isNew <> ephemeral Then Continue
		    keys.Add(k.StringValue)
		    nums.Add(Field(k.StringValue, ":", 1).ToInteger)
		  Next
		  nums.SortWith(keys)
		  Return keys
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function PortOwner(key As String) As String
		  Var bits() As String = key.ToArray(":")
		  Var port As Integer = bits(1).ToInteger
		  If bits(0) = "win" Then Return mWinPorts.Lookup(port, "?").StringValue
		  If mWslOwners.HasKey(port) Then Return mWslOwners.Value(port).StringValue + " (WSL)"
		  If mDockerPorts.HasKey(port) Then Return "docker " + mDockerPorts.Value(port).StringValue
		  Return "WSL (root process)"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ProbeWsl()
		  ' Never start a second wsl.exe while one is still out (a slow dockerd, say).
		  If mWslShell.IsRunning Then Return
		  ' Stage 1 only asks whether the distro is up, so the probe never boots it.
		  mWslStage = 1
		  mWslShell.Execute("wsl.exe -l --running -q")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub Refresh()
		  mDirty = False
		  Var up, down, degraded As Integer
		  Var bad() As String
		  Var lines() As String
		  Var worst As Integer = kStUp
		  For Each s As Dictionary In mServices
		    Var detail As String
		    Var st As Integer = Status(s, detail)
		    If Severity(st) > Severity(worst) Then worst = st
		    ' Remember which process serves each port while it is up, so a later move to
		    ' another port can be recognised (see MovedTo).
		    If st = kStUp And GetInt(s, "port", 0) > 0 And GetStr(s, "docker") = "" Then
		      Var who As String = Owner(s)
		      If who <> "" Then mLearnedOwner.Value(GetStr(s, "name")) = who
		    End If
		    lines.Add(GetStr(s, "name") + Chr(9) + If(GetStr(s, "side") = "server", GetStr(s, "host"), GetStr(s, "side")) + Chr(9) + GetInt(s, "port", 0).ToString + Chr(9) + StatusWord(st) + Chr(9) + detail)
		    Select Case st
		    Case kStUp
		      up = up + 1
		    Case kStDown
		      down = down + 1
		      bad.Add(GetStr(s, "name"))
		    Case kStDegraded
		      degraded = degraded + 1
		      bad.Add(GetStr(s, "name") + " (" + detail + ")")
		    End Select
		  Next

		  Var col As Color
		  Var tip As String
		  If mConfigError <> "" Then
		    col = kColorUnknown
		    tip = mConfigError
		  Else
		    Select Case worst
		    Case kStDown
		      col = kColorDown
		    Case kStDegraded
		      col = kColorBusy
		    Case kStUnknown
		      col = kColorUnknown
		    Else
		      col = kColorUp
		    End Select
		    tip = up.ToString + " up"
		    If degraded > 0 Then tip = tip + ", " + degraded.ToString + " degraded"
		    If down > 0 Then tip = tip + ", " + down.ToString + " down"
		    Var eph As Integer = PortKeys(True).Count
		    If eph > 0 Then tip = tip + ", " + eph.ToString + " ephemeral"
		    If bad.Count > 0 Then tip = tip + EndOfLine + String.FromArray(bad, ", ")
		  End If
		  If mRunning.KeyCount > 0 Then
		    Var models() As String
		    For Each k As Variant In mRunning.Keys
		      models.Add(k.StringValue + If(mRunning.Value(k).StringValue = "ready", "", " (" + mRunning.Value(k).StringValue + ")"))
		    Next
		    tip = tip + EndOfLine + "GPU: " + String.FromArray(models, ", ")
		  End If
		  If mVramTotal > 0 Then tip = tip + EndOfLine + VramText
		  ' Windows truncates tray tooltips at 127 characters.
		  If tip.Length > 120 Then tip = tip.Left(117) + "..."
		  mSummary = tip.ReplaceAll(EndOfLine, "   ·   ")

		  For Each k As String In PortKeys(True)
		    lines.Add("(ephemeral)" + Chr(9) + Field(k, ":", 0) + Chr(9) + Field(k, ":", 1) + Chr(9) + "listening" + Chr(9) + PortOwner(k) + ", since " + SeenText(k))
		  Next
		  For Each k As String In PortKeys(False)
		    lines.Add("(unlisted)" + Chr(9) + Field(k, ":", 0) + Chr(9) + Field(k, ":", 1) + Chr(9) + "listening" + Chr(9) + PortOwner(k))
		  Next
		  For Each k As Variant In mRunning.Keys
		    lines.Add("(model) " + k.StringValue + Chr(9) + "gpu" + Chr(9) + "0" + Chr(9) + mRunning.Value(k).StringValue + Chr(9))
		  Next
		  For Each k As Variant In mPortVerdict.Keys
		    lines.Add("(port check)" + Chr(9) + "win" + Chr(9) + k.StringValue + Chr(9) + "unbindable" + Chr(9) + mPortVerdict.Value(k).StringValue)
		  Next
		  If WriteStatus(lines) And mDetails <> Nil Then mDetails.Reload
		  If mDetails <> Nil Then mDetails.SetSummary(mSummary)

		  Var key As String = tip + "|" + col.Red.ToString + "," + col.Green.ToString + "," + col.Blue.ToString + "|" + mVramUsed.ToString
		  If key = mLastKey Then Return
		  mLastKey = key
		  mTray.Icon = MakeIcon(col)
		  mTray.Tooltip = tip
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub RefreshNow()
		  mHealthDue = New Dictionary
		  mSeconds = -1
		  mRemoteDue = 0
		  mGpuDue = 0
		  If mLlamaPolling Then PollLlama(True)
		  Tick(mTimer)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Row(kind As String, st As Integer, key As String, c0 As String, c1 As String, c2 As String, c3 As String, c4 As String, c5 As String) As Dictionary
		  Var cells() As String = Array(c0, c1, c2, c3, c4, c5)
		  Var d As New Dictionary
		  d.Value("kind") = kind
		  d.Value("status") = st
		  d.Value("key") = key
		  d.Value("cells") = cells
		  Return d
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub RunCommand(cmd As String)
		  ' "wsl:" commands run inside the distro; anything else runs on Windows.
		  Var line As String = cmd
		  If cmd.BeginsWith("wsl:") Then
		    line = "wsl.exe -d " + mDistro + " -e sh -c """ + cmd.Middle(4).ReplaceAll("""", "\""") + """"
		  End If
		  Var sh As New Shell
		  sh.ExecuteMode = Shell.ExecuteModes.Asynchronous
		  AddHandler sh.Completed, WeakAddressOf ActionCompleted
		  mActionShells.Add(sh)
		  sh.Execute(line)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub RunningReceived(sender As URLConnection, URL As String, HTTPStatus As Integer, content As String)
		  #Pragma Unused sender
		  #Pragma Unused URL
		  mLlamaUp = (HTTPStatus = 200)
		  Var r As New Dictionary
		  If mLlamaUp Then
		    Try
		      Var d As Dictionary = ParseJSON(content)
		      Var arr() As Variant = d.Value("running")
		      For Each v As Variant In arr
		        Var m As Dictionary = v
		        r.Value(m.Value("model").StringValue) = m.Value("state").StringValue
		      Next
		    Catch e As RuntimeException
		    End Try
		  End If
		  mRunning = r
		  mDirty = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function SeenText(key As String) As String
		  Var t As DateTime = mSeen.Lookup(key, Nil)
		  If t = Nil Then Return "start"
		  Return t.ToString(Locale.Current, DateTime.FormatStyles.None, DateTime.FormatStyles.Short)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ServiceByKey(key As String) As Dictionary
		  If Not key.BeginsWith("svc:") Then Return Nil
		  Var idx As Integer = key.Middle(4).ToInteger
		  If idx < 0 Or idx > mServices.LastIndex Then Return Nil
		  Return mServices(idx)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Severity(st As Integer) As Integer
		  Select Case st
		  Case kStDown
		    Return 3
		  Case kStDegraded
		    Return 2
		  Case kStUnknown
		    Return 1
		  End Select
		  Return 0
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ShowDetails()
		  If mDetails = Nil Then mDetails = New DetailsWindow
		  mDetails.Reload
		  mDetails.SetSummary(mSummary)
		  mDetails.Show
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ShowMenu()
		  ' Windows' own table is instant to read, so the menu always shows fresh ports.
		  mWinPorts = WinPorts.Listeners
		  mWinKnown = True
		  UpdateSeen("win", mWinPorts)
		  Refresh

		  Var m As New DesktopMenuItem
		  Var head As New DesktopMenuItem(If(mConfigError <> "", mConfigError, Field(mSummary, "   ·   ", 0)))
		  head.Enabled = False
		  m.AddMenu(head)
		  If mVramTotal > 0 Then
		    Var vram As New DesktopMenuItem(VramText)
		    vram.Enabled = False
		    m.AddMenu(vram)
		  End If

		  ' Every service stays visible. Sections and order follow the Preferences sort; a section
		  ' header carries its rollup in the right-hand column, categories are quiet sub-labels.
		  Var section As DesktopMenuItem
		  Var folded As Boolean
		  For Each li As Dictionary In Layout
		    Select Case li.Value("kind").StringValue
		    Case "head"
		      Var members() As Dictionary = li.Value("members")
		      Var ok, total As Integer
		      Var worst As Integer = Rollup(members, ok, total)
		      m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		      section = New DesktopMenuItem(li.Value("text").StringValue.Uppercase + Chr(9) + ok.ToString + "/" + total.ToString)
		      section.Icon = Dot(worst, True)
		      ' Optional: a fully healthy section folds into its header line. Headers stay
		      ' enabled even unfolded, because Windows greys a disabled item's icon.
		      folded = mCollapseHealthy And ok = total
		      m.AddMenu(section)
		    Case "sub"
		      Var label As New DesktopMenuItem("   " + li.Value("text").StringValue)
		      label.Enabled = False
		      If folded Then section.AddMenu(label) Else m.AddMenu(label)
		    Case "svc"
		      Var sv As Dictionary = li.Value("svc")
		      Var detail As String
		      Var stt As Integer = Status(sv, detail)
		      Var name As String = GetStr(sv, "name")
		      If mSortBy <> "environment" And GetStr(sv, "side") = "wsl" Then name = name + "  (WSL)"
		      If mSortBy <> "environment" And GetStr(sv, "side") = "server" Then name = name + "  (" + HostName(sv) + ")"
		      Var item As New DesktopMenuItem(MenuLine(name, stt, GetInt(sv, "port", 0), detail))
		      item.Icon = Dot(stt)
		      FillActions("svc:" + mServices.IndexOf(sv).ToString, item)
		      If folded Then section.AddMenu(item) Else m.AddMenu(item)
		      If sv = LlamaService Then
		        For Each k As Variant In mRunning.Keys
		          Var model As New DesktopMenuItem("      " + ModelLabel(k.StringValue) + Chr(9) + mRunning.Value(k).StringValue)
		          model.Enabled = False
		          If folded Then section.AddMenu(model) Else m.AddMenu(model)
		        Next
		      End If
		    End Select
		  Next

		  ' Listeners nobody configured. New ones (a dev server, a demo) get their own section.
		  Var eph() As String = PortKeys(True)
		  m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  Var eh As New DesktopMenuItem("EPHEMERAL" + Chr(9) + If(eph.Count = 0, "none", eph.Count.ToString))
		  eh.Icon = Dot(kStEphemeral, True)
		  m.AddMenu(eh)
		  For Each k As String In eph
		    Var item As New DesktopMenuItem(MenuLine(PortOwner(k), kStEphemeral, Field(k, ":", 1).ToInteger, "since " + SeenText(k)))
		    item.Icon = Dot(kStEphemeral)
		    FillActions("port:" + k, item)
		    m.AddMenu(item)
		  Next
		  Var other() As String = PortKeys(False)
		  Var oh As New DesktopMenuItem("Other listeners" + Chr(9) + other.Count.ToString)
		  oh.Icon = Dot(kStIdle)
		  For Each k As String In other
		    Var item As New DesktopMenuItem(PortOwner(k) + Chr(9) + ":" + Field(k, ":", 1))
		    FillActions("port:" + k, item)
		    oh.AddMenu(item)
		  Next
		  oh.Enabled = other.Count > 0
		  m.AddMenu(oh)
		  ' Reserved ports wait for programs that listen only now and then, so they fold away
		  ' too. The header's dot still turns amber when something else holds one.
		  Var res() As Dictionary = ReservedServices
		  If res.Count > 0 Then
		    Var ok, total As Integer
		    Var worst As Integer = Rollup(res, ok, total)
		    Var rh As New DesktopMenuItem("Reserved ports" + Chr(9) + If(ok = total, total.ToString, Str(total - ok) + " taken"))
		    rh.Icon = Dot(If(ok = total, kStIdle, worst))
		    For Each sv As Dictionary In res
		      Var detail As String
		      Var stt As Integer = Status(sv, detail)
		      Var name As String = GetStr(sv, "name")
		      If GetStr(sv, "side") = "wsl" Then name = name + "  (WSL)"
		      Var item As New DesktopMenuItem(MenuLine(name, stt, GetInt(sv, "port", 0), detail))
		      item.Icon = Dot(stt)
		      FillActions("svc:" + mServices.IndexOf(sv).ToString, item)
		      rh.AddMenu(item)
		    Next
		    m.AddMenu(rh)
		  End If

		  m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  m.AddMenu(New DesktopMenuItem("Details...", "details"))
		  m.AddMenu(New DesktopMenuItem("Check ports...", "checkports"))
		  m.AddMenu(New DesktopMenuItem("Refresh now", "refresh"))
		  m.AddMenu(New DesktopMenuItem("Preferences...", "prefs"))
		  m.AddMenu(New DesktopMenuItem("Edit services.json", "edit"))
		  m.AddMenu(New DesktopMenuItem("Reload services.json", "reload"))
		  m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  m.AddMenu(New DesktopMenuItem("Quit ServiceTray", "quit"))

		  Var choice As DesktopMenuItem = m.PopUp
		  If choice = Nil Or choice.Tag = Nil Then Return
		  DoAction(choice.Tag.StringValue)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Status(s As Dictionary, ByRef detail As String) As Integer
		  detail = ""
		  Var side As String = GetStr(s, "side")
		  Var port As Integer = GetInt(s, "port", 0)
		  ' "reserved": a port kept free for a program that only listens now and then (an
		  ' OAuth callback, say). Free is fine; it only matters who holds it.
		  Var isReserved As Boolean = s.HasKey("reserved") And s.Value("reserved").BooleanValue
		  Var isOptional As Boolean = isReserved Or (s.HasKey("optional") And s.Value("optional").BooleanValue)
		  Var listening As Boolean

		  If side = "wsl" Then
		    If Not mWslKnown Then Return kStUnknown
		    If Not mWslRunning Then
		      detail = "WSL not running"
		      Return If(isOptional, kStIdle, kStDown)
		    End If
		    Var ctName As String = GetStr(s, "docker")
		    If ctName <> "" Then
		      If Not mContainers.HasKey(ctName) Then
		        detail = "no container"
		        Return If(isOptional, kStIdle, kStDown)
		      End If
		      Var ct As String = mContainers.Value(ctName)
		      If Not ct.BeginsWith("Up") Then
		        detail = ct
		        Return If(isOptional, kStIdle, kStDown)
		      End If
		      If ct.IndexOf("(unhealthy)") >= 0 Then
		        detail = "unhealthy"
		        Return kStDegraded
		      End If
		      If ct.IndexOf("(health: starting)") >= 0 Then
		        detail = "starting"
		        Return kStDegraded
		      End If
		    End If
		    listening = (port = 0) Or mWslPorts.HasKey(port)
		  ElseIf side = "server" Then
		    ' Another machine: no port table, just whether a TCP connect succeeds (ProbeServers).
		    Var addr As String = GetStr(s, "host") + ":" + port.ToString
		    If port > 0 Then
		      If Not mRemote.HasKey(addr) Then Return kStUnknown
		      If Not mRemote.Value(addr).BooleanValue Then
		        detail = "no answer from " + addr
		        Return If(isOptional, kStIdle, kStDown)
		      End If
		    End If
		    listening = True
		  Else
		    If Not mWinKnown Then Return kStUnknown
		    listening = (port = 0) Or mWinPorts.HasKey(port)
		  End If

		  If Not listening Then
		    ' Its own process listening on a port nobody configured: the service moved and
		    ' services.json did not follow. Running, so degraded rather than down.
		    Var moved As Integer = If(isReserved, 0, MovedTo(s))
		    If moved > 0 Then
		      detail = PortOwner(side + ":" + moved.ToString) + " is listening on :" + moved.ToString + " instead"
		      Return kStDegraded
		    End If
		    detail = If(isReserved, "free (reserved)", If(isOptional, "not running", "not listening"))
		    ' A port check that found the port unbindable explains why nothing can listen.
		    If mPortVerdict.HasKey(port) Then detail = detail + ": port " + mPortVerdict.Value(port).StringValue
		    Return If(isOptional, kStIdle, kStDown)
		  End If

		  ' With "process" set, the port belongs to that program; anyone else holding it is a
		  ' conflict (the program will fail to bind when it needs the port).
		  If GetStr(s, "process") <> "" And GetStr(s, "docker") = "" Then
		    Var who As String = Owner(s)
		    If who <> "" And Not OwnerMatches(who, GetStr(s, "process")) Then
		      detail = "taken by " + who
		      Return kStDegraded
		    End If
		  End If
		  If isReserved Then detail = "in use"

		  If s = LlamaService And mRunning.KeyCount > 0 Then
		    For Each k As Variant In mRunning.Keys
		      If mRunning.Value(k).StringValue <> "ready" Then detail = k.StringValue + " " + mRunning.Value(k).StringValue
		    Next
		  End If

		  If GetStr(s, "health") <> "" Then
		    Var name As String = GetStr(s, "name")
		    If Not mHealth.HasKey(name) Then Return kStUp
		    Var code As Integer = mHealth.Value(name)
		    If code = 0 Then
		      detail = "no HTTP answer"
		      If mHealthMsg.HasKey(name) Then detail = detail + ": " + mHealthMsg.Value(name).StringValue
		      Return kStDegraded
		    ElseIf code >= 500 Then
		      detail = "HTTP " + code.ToString
		      Return kStDegraded
		    End If
		  End If
		  Return kStUp
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function StatusWord(st As Integer) As String
		  Select Case st
		  Case kStUp
		    Return "up"
		  Case kStIdle
		    Return "idle"
		  Case kStDegraded
		    Return "degraded"
		  Case kStDown
		    Return "down"
		  Case kStEphemeral
		    Return "new"
		  End Select
		  Return "unknown"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub Tick(sender As Timer)
		  #Pragma Unused sender
		  mSeconds = mSeconds + 1

		  Var winScanned As Boolean
		  If mSeconds Mod mWinEvery = 0 Then
		    mWinPorts = WinPorts.Listeners
		    mWinKnown = True
		    UpdateSeen("win", mWinPorts)
		    winScanned = True
		    mDirty = True
		    ' A changed services.json is reloaded on its own; the menu item stays for impatience.
		    Var f As FolderItem = ConfigFile
		    If f.Exists And f.ModificationDateTime.SecondsFrom1970 <> mConfigStamp Then Timer.CallLater(0, AddressOf ReloadConfig)
		  End If
		  ' While the details window is open, WSL is looked at more often.
		  Var wslEvery As Integer = If(mDetails <> Nil, Min(mWslEvery, 5), mWslEvery)
		  If mSeconds Mod wslEvery = 0 Then ProbeWsl

		  ' llama-swap pushes model changes over /api/events, so normally nothing is polled.
		  ' If the stream never delivers (or keeps failing), fall back to LlamaTray's polling.
		  If mLlamaUrl <> "" Then
		    If mLlamaPolling Then
		      If mSeconds Mod 3 = 0 Then PollLlama(mSeconds Mod 30 = 0)
		    ElseIf mEventsConn = Nil Then
		      If mSeconds >= mEventsRetryAt Then StartEvents
		    ElseIf Not mEventsAlive And mSeconds - mEventsStarted > 10 Then
		      mEventsConn.Disconnect
		      mEventsConn = Nil
		      mLlamaPolling = True
		    End If
		  End If

		  ' VRAM: nvidia-smi every 5 s while a model is loaded, every 30 s otherwise. A short
		  ' process now and then beats keeping nvml.dll and its driver parts resident.
		  If mSeconds >= mGpuDue Then
		    mGpuDue = mSeconds + If(mRunning.KeyCount > 0, 5, 30)
		    If mGpuShell = Nil Then
		      mGpuShell = New Shell
		      mGpuShell.ExecuteMode = Shell.ExecuteModes.Asynchronous
		      AddHandler mGpuShell.Completed, WeakAddressOf GpuCompleted
		    End If
		    If Not mGpuShell.IsRunning Then mGpuShell.Execute("nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits")
		  End If

		  If mSeconds >= mRemoteDue Then
		    mRemoteDue = mSeconds + mRemoteEvery
		    ProbeServers
		  End If
		  ' A machine that is off never answers a connect; after 8 s that counts as no answer.
		  For Each k As Variant In mRemoteConns.Keys
		    Var addr As String = mRemoteConns.Value(k)
		    If System.Microseconds - mRemoteStarted.Lookup(addr, 0.0).DoubleValue >= 8000000 Then RemoteDone(TCPSocket(k.ObjectValue), False)
		  Next

		  For Each s As Dictionary In mServices
		    Var name As String = GetStr(s, "name")
		    ' A required Windows service whose port went quiet: find out whether the port
		    ' itself got eaten (at most every 5 min per port; the bind lasts microseconds).
		    If winScanned And GetStr(s, "side") = "win" And GetInt(s, "port", 0) > 1023 Then
		      Var d As String
		      If Status(s, d) = kStDown And mSeconds >= mAutoChecked.Lookup(name, -1).IntegerValue Then
		        mAutoChecked.Value(name) = mSeconds + 300
		        Timer.CallLater(0, AddressOf AutoCheckPorts)
		      End If
		    End If
		    ' Health checks run on each service's own interval ("every", else healthEvery),
		    ' and only while its port is listening; a closed port already says it is down.
		    If GetStr(s, "health") = "" Then Continue
		    If mSeconds < mHealthDue.Lookup(name, 0).IntegerValue Then Continue
		    Var detail As String
		    Var st As Integer = Status(s, detail)
		    If st = kStUnknown Then Continue
		    mHealthDue.Value(name) = mSeconds + GetInt(s, "every", mHealthEvery)
		    If st = kStDown Or st = kStIdle Or MovedTo(s) > 0 Then
		      If mHealth.HasKey(name) Then mHealth.Remove(name)
		    Else
		      HealthCheck(s)
		    End If
		  Next

		  ' Everything above only marks the view dirty; it is rebuilt at most once a second.
		  If mDirty Then Refresh
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub UpdateSeen(side As String, ports As Dictionary)
		  ' Remember when each unlisted port first appeared. The first look at a side is the
		  ' baseline (value Nil = "already there"); anything after that counts as ephemeral.
		  Var baselined As Boolean = If(side = "win", mWinBaselined, mWslBaselined)
		  For Each k As Variant In ports.Keys
		    Var port As Integer = k.IntegerValue
		    If IsIgnored(port) Or IsListed(port, side) Then Continue
		    Var key As String = side + ":" + port.ToString
		    If Not mSeen.HasKey(key) Then
		      If baselined Then
		        mSeen.Value(key) = DateTime.Now
		      Else
		        mSeen.Value(key) = Nil
		      End If
		    End If
		  Next
		  Var gone() As String
		  For Each k As Variant In mSeen.Keys
		    Var bits() As String = k.StringValue.ToArray(":")
		    If bits(0) = side And Not ports.HasKey(bits(1).ToInteger) Then gone.Add(k.StringValue)
		  Next
		  For Each k As String In gone
		    mSeen.Remove(k)
		  Next
		  If side = "win" Then
		    mWinBaselined = True
		  Else
		    mWslBaselined = True
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function MovedTo(s As Dictionary) As Integer
		  ' The lowest unlisted port held by this service's own process (or container) while
		  ' its configured port is quiet, else 0. The process is the explicit "process" key,
		  ' the owner seen while it was last up, or an exe named like the service
		  ' ("Sonarr" -> Sonarr.exe). Ports in the ephemeral range and ignorePorts don't count.
		  Var side As String = GetStr(s, "side")
		  Var port As Integer = GetInt(s, "port", 0)
		  If port = 0 Or side = "server" Then Return 0
		  If side = "wsl" Then
		    If Not mWslKnown Or mWslPorts.HasKey(port) Then Return 0
		  Else
		    If Not mWinKnown Or mWinPorts.HasKey(port) Then Return 0
		  End If

		  Var want() As String
		  For Each alt As String In GetStr(s, "process").ToArray("|")
		    If alt.Trim <> "" Then want.Add(OwnerKey(alt.Trim))
		  Next
		  Var name As String = GetStr(s, "name")
		  If mLearnedOwner.HasKey(name) Then
		    ' A generic owner (python3, svchost) shared with another service proves nothing.
		    Var learned As String = mLearnedOwner.Value(name)
		    Var isShared As Boolean
		    For Each k As Variant In mLearnedOwner.Keys
		      If k.StringValue <> name And mLearnedOwner.Value(k).StringValue = learned Then isShared = True
		    Next
		    If Not isShared Then want.Add(OwnerKey(learned))
		  End If
		  want.Add(OwnerKey(name))
		  Var ct As String = GetStr(s, "docker")

		  Var table As Dictionary = If(side = "wsl", mWslPorts, mWinPorts)
		  Var best As Integer
		  For Each k As Variant In table.Keys
		    Var p As Integer = k.IntegerValue
		    If p = port Or IsIgnored(p) Or IsListed(p, side) Then Continue
		    If best > 0 And p >= best Then Continue
		    Var hit As Boolean
		    If side = "wsl" Then
		      If ct <> "" Then hit = mDockerPorts.Lookup(p, "").StringValue = ct
		      If Not hit And mWslOwners.HasKey(p) Then hit = want.IndexOf(OwnerKey(mWslOwners.Value(p).StringValue)) >= 0
		    Else
		      hit = want.IndexOf(OwnerKey(mWinPorts.Value(p).StringValue)) >= 0
		    End If
		    If hit Then best = p
		  Next
		  Return best
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function OwnerMatches(who As String, process As String) As Boolean
		  ' The Windows table can list several owners for one port ("tailscaled.exe, sshd.exe"),
		  ' and "process" can name alternatives ("codex|opencode" share one login callback).
		  For Each part As String In who.ToArray(",")
		    For Each alt As String In process.ToArray("|")
		      If OwnerKey(part.Trim.Replace(" (WSL)", "")) = OwnerKey(alt.Trim) Then Return True
		    Next
		  Next
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function OwnerKey(who As String) As String
		  ' "Sonarr.exe", "sonarr" and "Son arr" all compare equal.
		  Var k As String = who.Lowercase.ReplaceAll(" ", "")
		  If k.EndsWith(".exe") Then k = k.Left(k.Length - 4)
		  Return k
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ReloadConfig()
		  LoadConfig
		  mHealth = New Dictionary
		  mLastKey = ""
		  mLastStatus = ""
		  ' A port a service now claims is no longer an unlisted listener.
		  Var claimed() As String
		  For Each k As Variant In mSeen.Keys
		    If IsListed(Field(k.StringValue, ":", 1).ToInteger, Field(k.StringValue, ":", 0)) Then claimed.Add(k.StringValue)
		  Next
		  For Each k As String In claimed
		    mSeen.Remove(k)
		  Next
		  RefreshNow
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function SetServicePort(s As Dictionary, newPort As Integer) As Boolean
		  ' Rewrites only this service's object in services.json, as text, so the hand
		  ' formatting survives: its "port" and every ":<old>" in its URLs (health, open) follow.
		  ' The previous file is kept as services.json.bak.
		  If newPort <= 0 Or newPort > 65535 Then Return False
		  Var oldPort As Integer = GetInt(s, "port", 0)
		  Var f As FolderItem = ConfigFile
		  Var problem As String
		  Try
		    Var tin As TextInputStream = TextInputStream.Open(f)
		    Var body As String = tin.ReadAll(Encodings.UTF8)
		    tin.Close

		    Var re As New RegEx
		    re.SearchPattern = """name""\s*:\s*""" + RegexEscape(GetStr(s, "name")) + """"
		    Var m As RegExMatch = re.Search(body)
		    Var a, b As Integer
		    If m = Nil Then
		      problem = "its entry was not found"
		    ElseIf Not ObjectBounds(body, m.SubExpressionStartB(0), a, b) Then
		      problem = "its entry could not be delimited"
		    Else
		      Var obj As String = body.MiddleBytes(a, b - a)
		      Var rp As New RegEx
		      rp.Options.ReplaceAllMatches = True
		      If oldPort > 0 Then
		        rp.SearchPattern = """port""\s*:\s*" + oldPort.ToString + "\b"
		        rp.ReplacementPattern = """port"": " + newPort.ToString
		        obj = rp.Replace(obj)
		        rp.SearchPattern = ":" + oldPort.ToString + "(?=[/""])"
		        rp.ReplacementPattern = ":" + newPort.ToString
		        obj = rp.Replace(obj)
		      Else
		        obj = obj.Replace(m.SubExpressionString(0), m.SubExpressionString(0) + ", ""port"": " + newPort.ToString)
		      End If
		      Var bak As TextOutputStream = TextOutputStream.Create(f.Parent.Child("services.json.bak"))
		      bak.Write(body)
		      bak.Close
		      Var out As TextOutputStream = TextOutputStream.Create(f)
		      out.Write(body.LeftBytes(a) + obj + body.MiddleBytes(b))
		      out.Close
		    End If
		  Catch e As RuntimeException
		    problem = e.Message
		  End Try
		  If problem <> "" Then
		    MessageBox("Could not change the port of " + GetStr(s, "name") + ": " + problem + "." + EndOfLine + "Use Edit services.json instead.")
		    Return False
		  End If
		  ReloadConfig
		  Return True
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ObjectBounds(body As String, pos As Integer, ByRef a As Integer, ByRef b As Integer) As Boolean
		  ' Byte offsets [a, b) of the innermost JSON object around byte pos, skipping strings.
		  Var mb As MemoryBlock = body
		  Var stack() As Integer
		  Var depth As Integer = -1
		  Var inStr, esc As Boolean
		  For i As Integer = 0 To mb.Size - 1
		    If i = pos Then
		      If stack.Count = 0 Then Return False
		      depth = stack.Count
		      a = stack(stack.LastIndex)
		    End If
		    Var c As Integer = mb.Byte(i)
		    If inStr Then
		      If esc Then
		        esc = False
		      ElseIf c = 92 Then
		        esc = True
		      ElseIf c = 34 Then
		        inStr = False
		      End If
		    ElseIf c = 34 Then
		      inStr = True
		    ElseIf c = 123 Then
		      stack.Add(i)
		    ElseIf c = 125 And stack.Count > 0 Then
		      If stack.Count = depth Then
		        b = i + 1
		        Return True
		      End If
		      stack.RemoveAt(stack.LastIndex)
		    End If
		  Next
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function RegexEscape(s As String) As String
		  Var out As String = s
		  For Each ch As String In Array("\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}")
		    out = out.ReplaceAll(ch, "\" + ch)
		  Next
		  Return out
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function VramText() As String
		  Return "VRAM " + Format(mVramUsed / 1024, "0.0") + " / " + Format(mVramTotal / 1024, "0.0") + " GB"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function WriteStatus(lines() As String) As Boolean
		  ' status.txt mirrors the menu for scripts and agents (tab-separated). It is only
		  ' rewritten when something changed, so an idle machine causes no disk writes.
		  ' Returns True when it changed, which is also when the details window redraws.
		  Var body As String = String.FromArray(lines, EndOfLine.Windows)
		  If body = mLastStatus Then Return False
		  mLastStatus = body
		  Try
		    Var out As TextOutputStream = TextOutputStream.Create(ConfigFile.Parent.Child("status.txt"))
		    out.Write("name" + Chr(9) + "side" + Chr(9) + "port" + Chr(9) + "status" + Chr(9) + "detail" + EndOfLine.Windows + body + EndOfLine.Windows)
		    out.Close
		  Catch e As IOException
		  End Try
		  Return True
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub WslCompleted(sender As Shell)
		  If mWslStage = 1 Then
		    ' wsl.exe -l writes UTF-16LE, so look for the distro name in that encoding.
		    mWslRunning = sender.Result.IndexOfBytes(mDistro.ConvertEncoding(Encodings.UTF16LE)) >= 0
		    If Not mWslRunning Then
		      mWslKnown = True
		      mWslPorts = New Dictionary
		      mContainers = New Dictionary
		      UpdateSeen("wsl", mWslPorts)
		      ' A distro that boots later brings its own baseline, not a burst of "new" ports.
		      mWslBaselined = False
		      mDirty = True
		      Return
		    End If
		    ' Started from a fresh event, not from inside this Shell's own Completed.
		    mWslStage = 2
		    Timer.CallLater(0, AddressOf WslStage2)
		    Return
		  End If

		  Var out As String = sender.Result.DefineEncoding(Encodings.UTF8).ReplaceAll(EndOfLine.Windows, EndOfLine.UNIX)
		  Var parts() As String = out.ToArray("===")
		  Var ports As New Dictionary
		  Var owners As New Dictionary
		  Var cts As New Dictionary
		  Var dports As New Dictionary
		  If parts.Count >= 1 Then
		    ' "LISTEN 0 4096 0.0.0.0:3001 0.0.0.0:* users:((""python3"",pid=9,fd=3))": the fourth
		    ' field is the local address; the process shows only for your own processes.
		    For Each line As String In parts(0).ToArray(EndOfLine.UNIX)
		      Var f() As String = Words(line)
		      If f.Count < 4 Then Continue
		      ' IPv6 addresses contain colons too; the port is always after the last one.
		      Var bits() As String = f(3).ToArray(":")
		      Var port As Integer = bits(bits.LastIndex).ToInteger
		      If port <= 0 Then Continue
		      ports.Value(port) = True
		      If f.Count >= 6 And f(5).IndexOf("""") >= 0 Then owners.Value(port) = Field(f(5), """", 1)
		    Next
		  End If
		  If parts.Count >= 2 Then
		    For Each line As String In parts(1).ToArray(EndOfLine.UNIX)
		      If line.Trim = "" Then Continue
		      Try
		        Var d As Dictionary = ParseJSON(line)
		        Var name As String = GetStr(d, "Names")
		        cts.Value(name) = GetStr(d, "Status")
		        ' "0.0.0.0:3005->5000/tcp, [::]:3005->5000/tcp": the host port is before "->".
		        For Each mapping As String In GetStr(d, "Ports").ToArray(",")
		          If mapping.IndexOf("->") < 0 Then Continue
		          Var hostSide() As String = Field(mapping, "->", 0).ToArray(":")
		          Var hp As Integer = hostSide(hostSide.LastIndex).ToInteger
		          If hp > 0 Then dports.Value(hp) = name
		        Next
		      Catch e As RuntimeException
		      End Try
		    Next
		  End If
		  mWslPorts = ports
		  mWslOwners = owners
		  mContainers = cts
		  mDockerPorts = dports
		  mWslKnown = True
		  UpdateSeen("wsl", mWslPorts)
		  mDirty = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub WslStage2()
		  ' One process for both questions: listening ports (with owners), then every container.
		  mWslShell.Execute("wsl.exe -d " + mDistro + " -e sh -c ""ss -ltnpH; echo ===; docker ps -a --format '{{json .}}'""")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Words(line As String) As String()
		  Var out() As String
		  For Each w As String In line.ReplaceAll(Chr(9), " ").ToArray(" ")
		    If w <> "" Then out.Add(w)
		  Next
		  Return out
		End Function
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mRemote As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRemoteConns As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRemoteDue As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRemoteEvery As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRemoteStarted As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServerNames As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServerTitle As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mConfigStamp As Double
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLearnedOwner As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSortBy As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mShowCategories As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHideIdle As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPortFrom As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPortTo As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPrefs As PrefsWindow
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDirty As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEventsAlive As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEventsConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEventsRetryAt As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEventsStarted As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mGpuDue As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mGpuShell As Shell
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLlamaPolling As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSseBuf As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mActions() As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mActionShells() As Shell
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mActionWhat() As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mAutoChecked As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCheckPorts() As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCollapseHealthy As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mConfigError As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mContainers As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDetails As DetailsWindow
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDistro As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDockerPorts As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealth As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthConns As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthDue As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthEvery As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthMsg As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mIgnoreFrom As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mIgnorePorts() As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLastKey As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLastStatus As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLlamaConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLlamaName As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLlamaUp As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLlamaUrl As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mModelNames As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mModels() As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mModelsConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPortCheckCount As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPortCheckTime As DateTime
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPortVerdict As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDots As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRunning As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSeconds As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSeen As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServices() As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSummary As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTray As TrayIcon
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mVramTotal As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mVramUsed As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWinBaselined As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWinEvery As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWinKnown As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWinPorts As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslBaselined As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslEvery As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslKnown As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslOwners As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslPorts As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslRunning As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslShell As Shell
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslStage As Integer
	#tag EndProperty


	#tag Constant, Name = kColorBusy, Type = Color, Dynamic = False, Default = \"&cE67E22", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kColorDown, Type = Color, Dynamic = False, Default = \"&cC0392B", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kColorUnknown, Type = Color, Dynamic = False, Default = \"&c7F8C8D", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kColorUp, Type = Color, Dynamic = False, Default = \"&c27AE60", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kEditClear, Type = String, Dynamic = False, Default = \"&Delete", Scope = Public
		#Tag Instance, Platform = Windows, Language = Default, Definition  = \"&Delete"
		#Tag Instance, Platform = Linux, Language = Default, Definition  = \"&Delete"
	#tag EndConstant

	#tag Constant, Name = kFileQuit, Type = String, Dynamic = False, Default = \"&Quit", Scope = Public
		#Tag Instance, Platform = Windows, Language = Default, Definition  = \"E&xit"
	#tag EndConstant

	#tag Constant, Name = kFileQuitShortcut, Type = String, Dynamic = False, Default = \"", Scope = Public
		#Tag Instance, Platform = Mac OS, Language = Default, Definition  = \"Cmd+Q"
		#Tag Instance, Platform = Linux, Language = Default, Definition  = \"Ctrl+Q"
	#tag EndConstant

	#tag Constant, Name = kStDegraded, Type = Double, Dynamic = False, Default = \"3", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kStDown, Type = Double, Dynamic = False, Default = \"4", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kStEphemeral, Type = Double, Dynamic = False, Default = \"5", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kStIdle, Type = Double, Dynamic = False, Default = \"2", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kStUnknown, Type = Double, Dynamic = False, Default = \"0", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kStUp, Type = Double, Dynamic = False, Default = \"1", Scope = Public
	#tag EndConstant


End Class
#tag EndClass
