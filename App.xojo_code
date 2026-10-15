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
		  ' No windows: the tray icon is the whole UI.
		  AllowAutoQuit = False
		  mWinPorts = New Dictionary
		  mWslPorts = New Dictionary
		  mContainers = New Dictionary
		  mHealth = New Dictionary
		  mHealthDue = New Dictionary
		  mHealthConns = New Dictionary
		  mHealthMsg = New Dictionary

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
		Private Function ConfigFile() As FolderItem
		  Var dir As FolderItem = SpecialFolder.ApplicationData.Child("ServiceTray")
		  If Not dir.Exists Then dir.CreateFolder
		  Return dir.Child("services.json")
		End Function
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
		Private Sub LoadConfig()
		  mServices.RemoveAll
		  mIgnorePorts.RemoveAll
		  mConfigError = ""
		  mDistro = "Debian"
		  mWinEvery = 5
		  mWslEvery = 15
		  mHealthEvery = 30
		  mIgnoreFrom = 49152

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
		    If d.HasKey("ignorePorts") Then
		      Var ports() As Variant = d.Value("ignorePorts")
		      For Each p As Variant In ports
		        mIgnorePorts.Add(p.IntegerValue)
		      Next
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
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function MakeIcon(c As Color) As Picture
		  ' A filled disc in the colour of the worst service state.
		  Var p As New Picture(32, 32)
		  Var g As Graphics = p.Graphics
		  g.AntiAliased = True
		  g.DrawingColor = c
		  g.FillOval(1, 1, 30, 30)
		  g.DrawingColor = &cFFFFFF00
		  g.FillOval(11, 11, 10, 10)
		  Return p
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
		    If bad.Count > 0 Then tip = tip + EndOfLine + String.FromArray(bad, ", ")
		  End If
		  ' Windows truncates tray tooltips at 127 characters.
		  If tip.Length > 120 Then tip = tip.Left(117) + "..."

		  WriteStatus(lines)

		  Var key As String = tip + "|" + col.Red.ToString + "," + col.Green.ToString + "," + col.Blue.ToString
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
		Sub ShowMenu()
		  ' Windows' own table is instant to read, so the menu always shows fresh ports.
		  mWinPorts = WinPorts.Listeners
		  mWinKnown = True
		  Refresh

		  Var m As New DesktopMenuItem
		  If mConfigError <> "" Then
		    Var err As New DesktopMenuItem(mConfigError)
		    err.Enabled = False
		    m.AddMenu(err)
		    m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  End If

		  Var sides() As String = Array("win", "wsl")
		  For Each side As String In sides
		    Var head As New DesktopMenuItem(If(side = "win", "Windows", "WSL (" + mDistro + ")" + If(mWslKnown And Not mWslRunning, ": not running", "")))
		    head.Enabled = False
		    m.AddMenu(head)
		    For Each s As Dictionary In mServices
		      If GetStr(s, "side") <> side Then Continue
		      m.AddMenu(ServiceItem(s))
		    Next
		  Next

		  ' Listeners nobody put in services.json: strays, forgotten servers, 0.0.0.0 surprises.
		  Var extra As New DesktopMenuItem("Unlisted listeners")
		  For Each k As Variant In mWinPorts.Keys
		    Var port As Integer = k.IntegerValue
		    If IsIgnored(port) Or IsListed(port, "win") Then Continue
		    extra.AddMenu(New DesktopMenuItem(":" + port.ToString + "   " + mWinPorts.Value(k).StringValue, "copy:" + port.ToString))
		  Next
		  For Each k As Variant In mWslPorts.Keys
		    Var port As Integer = k.IntegerValue
		    If IsIgnored(port) Or IsListed(port, "wsl") Then Continue
		    extra.AddMenu(New DesktopMenuItem(":" + port.ToString + "   WSL", "copy:" + port.ToString))
		  Next
		  extra.Text = "Unlisted listeners (" + extra.Count.ToString + ")"
		  extra.Enabled = extra.Count > 0
		  m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  m.AddMenu(extra)

		  m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  m.AddMenu(New DesktopMenuItem("Refresh now", "refresh"))
		  m.AddMenu(New DesktopMenuItem("Edit services.json", "edit"))
		  m.AddMenu(New DesktopMenuItem("Reload services.json", "reload"))
		  m.AddMenu(New DesktopMenuItem(DesktopMenuItem.TextSeparator))
		  m.AddMenu(New DesktopMenuItem("Quit ServiceTray", "quit"))

		  Var choice As DesktopMenuItem = m.PopUp
		  If choice = Nil Or choice.Tag = Nil Then Return
		  Var tag As String = choice.Tag.StringValue

		  If tag.BeginsWith("open:") Then
		    System.GotoURL(tag.Middle(5))
		  ElseIf tag.BeginsWith("copy:") Then
		    Var c As New Clipboard
		    c.Text = tag.Middle(5)
		    c.Close
		  ElseIf tag.BeginsWith("restart:") Then
		    Var idx As Integer = tag.Middle(8).ToInteger
		    If idx < 0 Or idx > mServices.LastIndex Then Return
		    Var s As Dictionary = mServices(idx)
		    Var d As New MessageDialog
		    d.Message = "Restart " + GetStr(s, "name") + "?"
		    d.Explanation = GetStr(s, "restart")
		    d.ActionButton.Caption = "Restart"
		    d.CancelButton.Visible = True
		    If d.ShowModal = d.ActionButton Then RunCommand(GetStr(s, "restart"))
		  ElseIf tag = "refresh" Then
		    RefreshNow
		  ElseIf tag = "edit" Then
		    ConfigFile.Open
		  ElseIf tag = "reload" Then
		    LoadConfig
		    mHealth = New Dictionary
		    mLastKey = ""
		    RefreshNow
		  ElseIf tag = "quit" Then
		    Quit
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ServiceItem(s As Dictionary) As DesktopMenuItem
		  Var detail As String
		  Var st As Integer = Status(s, detail)
		  Var mark As String
		  Select Case st
		  Case kStUp
		    mark = "✓"
		  Case kStIdle
		    mark = "○"
		  Case kStDegraded
		    mark = "!"
		  Case kStDown
		    mark = "✗"
		  Else
		    mark = "…"
		  End Select

		  Var port As Integer = GetInt(s, "port", 0)
		  Var caption As String = mark + "  " + GetStr(s, "name")
		  If port > 0 Then caption = caption + "   :" + port.ToString
		  If detail <> "" Then caption = caption + "   " + detail
		  Var item As New DesktopMenuItem(caption)

		  Var url As String = GetStr(s, "open")
		  If url <> "" Then item.AddMenu(New DesktopMenuItem("Open " + url, "open:" + url))
		  If GetStr(s, "restart") <> "" Then item.AddMenu(New DesktopMenuItem("Restart...", "restart:" + mServices.IndexOf(s).ToString))
		  If port > 0 Then item.AddMenu(New DesktopMenuItem("Copy port", "copy:" + port.ToString))
		  If GetStr(s, "side") = "win" And mWinPorts.HasKey(port) Then
		    Var owner As New DesktopMenuItem("Owner: " + mWinPorts.Value(port).StringValue)
		    owner.Enabled = False
		    item.AddMenu(owner)
		  End If
		  If GetStr(s, "docker") <> "" Then
		    Var ct As New DesktopMenuItem("Container " + GetStr(s, "docker") + ": " + mContainers.Lookup(GetStr(s, "docker"), "not found").StringValue)
		    ct.Enabled = False
		    item.AddMenu(ct)
		  End If
		  Return item
		End Function
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
		    Return If(isOptional, kStIdle, kStDown)
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
		  End Select
		  Return "unknown"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub WriteStatus(lines() As String)
		  ' status.txt mirrors the menu for scripts and agents (tab-separated). It is only
		  ' rewritten when something changed, so an idle machine causes no disk writes.
		  For Each k As Variant In mWinPorts.Keys
		    If Not IsIgnored(k.IntegerValue) And Not IsListed(k.IntegerValue, "win") Then lines.Add("(unlisted)" + Chr(9) + "win" + Chr(9) + k.StringValue + Chr(9) + "listening" + Chr(9) + mWinPorts.Value(k).StringValue)
		  Next
		  For Each k As Variant In mWslPorts.Keys
		    If Not IsIgnored(k.IntegerValue) And Not IsListed(k.IntegerValue, "wsl") Then lines.Add("(unlisted)" + Chr(9) + "wsl" + Chr(9) + k.StringValue + Chr(9) + "listening" + Chr(9))
		  Next
		  Var body As String = String.FromArray(lines, EndOfLine.Windows)
		  If body = mLastStatus Then Return
		  mLastStatus = body
		  Try
		    Var out As TextOutputStream = TextOutputStream.Create(ConfigFile.Parent.Child("status.txt"))
		    out.Write("name" + Chr(9) + "side" + Chr(9) + "port" + Chr(9) + "status" + Chr(9) + "detail" + EndOfLine.Windows + body + EndOfLine.Windows)
		    out.Close
		  Catch e As IOException
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub Tick(sender As Timer)
		  #Pragma Unused sender
		  mSeconds = mSeconds + 1

		  If mSeconds Mod mWinEvery = 0 Then
		    mWinPorts = WinPorts.Listeners
		    mWinKnown = True
		  End If
		  If mSeconds Mod mWslEvery = 0 Then ProbeWsl

		  ' Health checks run on each service's own interval ("every", else healthEvery),
		  ' and only while its port is listening; a closed port already says it is down.
		  For Each s As Dictionary In mServices
		    If GetStr(s, "health") = "" Then Continue
		    Var name As String = GetStr(s, "name")
		    If mSeconds < mHealthDue.Lookup(name, 0).IntegerValue Then Continue
		    Var detail As String
		    Var st As Integer = Status(s, detail)
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
		Private Sub WslCompleted(sender As Shell)
		  If mWslStage = 1 Then
		    ' wsl.exe -l writes UTF-16LE, so look for the distro name in that encoding.
		    mWslRunning = sender.Result.IndexOfBytes(mDistro.ConvertEncoding(Encodings.UTF16LE)) >= 0
		    If Not mWslRunning Then
		      mWslKnown = True
		      mWslPorts = New Dictionary
		      mContainers = New Dictionary
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
		  Var cts As New Dictionary
		  If parts.Count >= 1 Then
		    ' "LISTEN 0 4096 0.0.0.0:3001 0.0.0.0:*": the fourth field is the local address.
		    For Each line As String In parts(0).ToArray(EndOfLine.UNIX)
		      Var f() As String = Words(line)
		      If f.Count < 4 Then Continue
		      ' IPv6 addresses contain colons too; the port is always after the last one.
		      Var bits() As String = f(3).ToArray(":")
		      Var port As Integer = bits(bits.LastIndex).ToInteger
		      If port > 0 Then ports.Value(port) = True
		    Next
		  End If
		  If parts.Count >= 2 Then
		    For Each line As String In parts(1).ToArray(EndOfLine.UNIX)
		      If line.Trim = "" Then Continue
		      Try
		        Var d As Dictionary = ParseJSON(line)
		        cts.Value(GetStr(d, "Names")) = GetStr(d, "Status")
		      Catch e As RuntimeException
		      End Try
		    Next
		  End If
		  mWslPorts = ports
		  mContainers = cts
		  mWslKnown = True
		  Refresh
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub WslStage2()
		  ' One process for both questions: listening ports, then every container's status.
		  mWslShell.Execute("wsl.exe -d " + mDistro + " -e sh -c ""ss -ltnH; echo ===; docker ps -a --format '{{json .}}'""")
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
		Private mActionShells() As Shell
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mConfigError As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mContainers As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDistro As String
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
		Private mHealthMsg As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthEvery As Integer
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
		Private mSeconds As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServices() As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTray As TrayIcon
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
		Private mWslEvery As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mWslKnown As Boolean
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

	#tag Constant, Name = kStDegraded, Type = Double, Dynamic = False, Default = \"3", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kStDown, Type = Double, Dynamic = False, Default = \"4", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kStIdle, Type = Double, Dynamic = False, Default = \"2", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kStUnknown, Type = Double, Dynamic = False, Default = \"0", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kStUp, Type = Double, Dynamic = False, Default = \"1", Scope = Private
	#tag EndConstant


End Class
#tag EndClass
