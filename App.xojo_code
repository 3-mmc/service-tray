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
		      "    " + GetStr(sv, "name"), StatusWord(stt), If(port > 0, port.ToString, ""), If(GetStr(sv, "side") = "wsl", "WSL", "Windows"), Owner(sv), detail))
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
		    LoadConfig
		    mHealth = New Dictionary
		    mLastKey = ""
		    mLastStatus = ""
		    RefreshNow
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
		  Return If(GetStr(s, "side") = "wsl", "WSL", "Windows")
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
		  Refresh
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub HealthReceived(sender As URLConnection, URL As String, HTTPStatus As Integer, content As String)
		  #Pragma Unused URL
		  #Pragma Unused content
		  If Not mHealthConns.HasKey(sender) Then Return
		  mHealth.Value(mHealthConns.Value(sender).StringValue) = HTTPStatus
		  mHealthConns.Remove(sender)
		  Refresh
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsIgnored(port As Integer) As Boolean
		  If port >= mIgnoreFrom Then Return True
		  Return mIgnorePorts.IndexOf(port) >= 0
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
		  PollLlama(False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LlamaActionError(sender As URLConnection, e As RuntimeException)
		  Var what As String = LlamaForget(sender)
		  MessageBox("Request to llama-swap (" + what + ") failed: " + e.Message)
		  PollLlama(False)
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
		  Refresh
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

		  Var f As FolderItem = ConfigFile
		  If Not f.Exists Then
		    Var out As TextOutputStream = TextOutputStream.Create(f)
		    out.Write("{" + EndOfLine + "  ""services"": []" + EndOfLine + "}" + EndOfLine)
		    out.Close
		    mConfigError = "No services configured yet"
		    Return
		  End If

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
		    ' Environment: Windows, then WSL, each with its categories as sub-labels.
		    Var sides() As String = Array("win", "wsl")
		    For Each side As String In sides
		      Var members() As Dictionary
		      For Each sv As Dictionary In shown
		        If GetStr(sv, "side") = side Then members.Add(sv)
		      Next
		      AddSection(out, If(side = "win", "Windows", "WSL (" + mDistro + ")" + If(mWslKnown And Not mWslRunning, ": not running", "")), members, mShowCategories)
		    Next
		  End Select
		  Return out
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub AddSection(out() As Dictionary, title As String, members() As Dictionary, withCategories As Boolean)
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
		  ' Categories in config order; a service without one sits at the top of the section.
		  Var cats() As String
		  For Each sv As Dictionary In members
		    If cats.IndexOf(GetStr(sv, "group")) < 0 Then cats.Add(GetStr(sv, "group"))
		  Next
		  For Each c As String In cats
		    If c <> "" Then out.Add(MakeEntry("sub", c, Nil))
		    For Each sv As Dictionary In members
		      If GetStr(sv, "group") = c Then out.Add(MakeEntry("svc", "", sv))
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
		  ' Name (and detail) on the left; after the tab, Windows right-aligns the mark and
		  ' port into one column, so the whole menu lines up.
		  Var left As String = name
		  If detail <> "" Then left = left + "  -  " + detail
		  Var right As String = Mark(st)
		  If port > 0 Then right = right + "   :" + port.ToString
		  Return left + Chr(9) + right
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
		  Var up, down, degraded As Integer
		  Var bad() As String
		  Var lines() As String
		  Var worst As Integer = kStUp
		  For Each s As Dictionary In mServices
		    Var detail As String
		    Var st As Integer = Status(s, detail)
		    If Severity(st) > Severity(worst) Then worst = st
		    lines.Add(GetStr(s, "name") + Chr(9) + GetStr(s, "side") + Chr(9) + GetInt(s, "port", 0).ToString + Chr(9) + StatusWord(st) + Chr(9) + detail)
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
		  Refresh
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
		      section = New DesktopMenuItem(li.Value("text").StringValue.Uppercase + Chr(9) + Mark(worst) + "   " + ok.ToString + "/" + total.ToString)
		      ' Optional: a fully healthy section folds into its header line.
		      folded = mCollapseHealthy And ok = total
		      section.Enabled = folded
		      m.AddMenu(section)
		    Case "sub"
		      Var label As New DesktopMenuItem("   ·  " + li.Value("text").StringValue)
		      label.Enabled = False
		      If folded Then section.AddMenu(label) Else m.AddMenu(label)
		    Case "svc"
		      Var sv As Dictionary = li.Value("svc")
		      Var detail As String
		      Var stt As Integer = Status(sv, detail)
		      Var name As String = GetStr(sv, "name")
		      If mSortBy <> "environment" And GetStr(sv, "side") = "wsl" Then name = name + "  (WSL)"
		      Var item As New DesktopMenuItem(MenuLine("      " + name, stt, GetInt(sv, "port", 0), detail))
		      FillActions("svc:" + mServices.IndexOf(sv).ToString, item)
		      If folded Then section.AddMenu(item) Else m.AddMenu(item)
		      If sv = LlamaService Then
		        For Each k As Variant In mRunning.Keys
		          Var model As New DesktopMenuItem("            " + ModelLabel(k.StringValue) + Chr(9) + mRunning.Value(k).StringValue)
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
		  eh.Enabled = False
		  m.AddMenu(eh)
		  For Each k As String In eph
		    Var item As New DesktopMenuItem(MenuLine("      " + PortOwner(k), kStEphemeral, Field(k, ":", 1).ToInteger, "since " + SeenText(k)))
		    FillActions("port:" + k, item)
		    m.AddMenu(item)
		  Next
		  Var other() As String = PortKeys(False)
		  Var oh As New DesktopMenuItem("      Other listeners" + Chr(9) + other.Count.ToString)
		  For Each k As String In other
		    Var item As New DesktopMenuItem(PortOwner(k) + Chr(9) + ":" + Field(k, ":", 1))
		    FillActions("port:" + k, item)
		    oh.AddMenu(item)
		  Next
		  oh.Enabled = other.Count > 0
		  m.AddMenu(oh)

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
		  Var isOptional As Boolean = s.HasKey("optional") And s.Value("optional").BooleanValue
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
		  Else
		    If Not mWinKnown Then Return kStUnknown
		    listening = (port = 0) Or mWinPorts.HasKey(port)
		  End If

		  If Not listening Then
		    detail = If(isOptional, "not running", "not listening")
		    ' A port check that found the port unbindable explains why nothing can listen.
		    If mPortVerdict.HasKey(port) Then detail = detail + ": port " + mPortVerdict.Value(port).StringValue
		    Return If(isOptional, kStIdle, kStDown)
		  End If

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

		  If mSeconds Mod mWinEvery = 0 Then
		    mWinPorts = WinPorts.Listeners
		    mWinKnown = True
		    UpdateSeen("win", mWinPorts)
		  End If
		  ' While the details window is open, WSL is looked at more often.
		  Var wslEvery As Integer = If(mDetails <> Nil, Min(mWslEvery, 5), mWslEvery)
		  If mSeconds Mod wslEvery = 0 Then ProbeWsl

		  ' llama-swap keeps LlamaTray's cadence: /running every 3 s, the model list every 30 s.
		  ' VRAM is an in-process NVML call, so it costs nothing to keep in step.
		  If mSeconds Mod 3 = 0 Then
		    PollLlama(mSeconds Mod 30 = 0)
		    Call Gpu.ReadVram(mVramUsed, mVramTotal)
		  End If

		  ' Health checks run on each service's own interval ("every", else healthEvery),
		  ' and only while its port is listening; a closed port already says it is down.
		  For Each s As Dictionary In mServices
		    Var name As String = GetStr(s, "name")
		    Var detail As String
		    Var st As Integer = Status(s, detail)
		    ' A required Windows service whose port went quiet: find out at once whether the
		    ' port itself got eaten (at most every 5 min per port; the bind lasts microseconds).
		    If st = kStDown And GetStr(s, "side") = "win" And GetInt(s, "port", 0) > 1023 Then
		      If mSeconds >= mAutoChecked.Lookup(name, -1).IntegerValue Then
		        mAutoChecked.Value(name) = mSeconds + 300
		        Timer.CallLater(0, AddressOf AutoCheckPorts)
		      End If
		    End If
		    If GetStr(s, "health") = "" Then Continue
		    If mSeconds < mHealthDue.Lookup(name, 0).IntegerValue Then Continue
		    If st = kStUnknown Then Continue
		    mHealthDue.Value(name) = mSeconds + GetInt(s, "every", mHealthEvery)
		    If st = kStDown Or st = kStIdle Then
		      If mHealth.HasKey(name) Then mHealth.Remove(name)
		    Else
		      HealthCheck(s)
		    End If
		  Next

		  Refresh
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
		      Refresh
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
		  Refresh
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
