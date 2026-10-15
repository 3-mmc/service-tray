#tag Module
Protected Module WinPorts
	#tag Method, Flags = &h0
		Function Listeners() As Dictionary
		  ' Listening TCP ports (IPv4 and IPv6) -> owning exe name, read straight from the
		  ' IP Helper API. No netstat process, no cp850 parsing. WSL's ports never appear
		  ' here under mirrored networking; those come from the WSL probe instead.
		  Var result As New Dictionary
		  #If TargetWindows
		    Declare Function GetExtendedTcpTable Lib "iphlpapi.dll" (table As Ptr, ByRef size As UInt32, order As Int32, af As UInt32, tableClass As Int32, reserved As UInt32) As UInt32
		    Const kListener = 3 ' TCP_TABLE_OWNER_PID_LISTENER
		    ' Process names are cached between scans; a fresh Toolhelp snapshot is taken only
		    ' for an unknown pid, or once a minute so a reused pid cannot keep a stale name.
		    If mNames = Nil Or mNamesAt = Nil Or DateTime.Now.SecondsFrom1970 - mNamesAt.SecondsFrom1970 > 60 Then
		      mNames = ProcessNames
		      mNamesAt = DateTime.Now
		    End If
		    Var names As Dictionary = mNames
		    mRetook = False
		    Var families() As Integer = Array(2, 23) ' AF_INET, AF_INET6
		    For Each af As Integer In families
		      ' MIB_TCPROW_OWNER_PID is 24 bytes (port at 8, pid at 20);
		      ' MIB_TCP6ROW_OWNER_PID is 56 bytes (port at 20, pid at 52).
		      Var rowSize As Integer = If(af = 2, 24, 56)
		      Var portOff As Integer = If(af = 2, 8, 20)
		      Var pidOff As Integer = If(af = 2, 20, 52)

		      Var size As UInt32 = 0
		      Call GetExtendedTcpTable(Nil, size, 0, af, kListener, 0)
		      If size = 0 Then Continue
		      Var mb As MemoryBlock
		      Var rc As UInt32 = 122
		      ' The table can grow between the size query and the read; retry with headroom.
		      For attempt As Integer = 1 To 3
		        mb = New MemoryBlock(size + 2048)
		        size = mb.Size
		        rc = GetExtendedTcpTable(mb, size, 0, af, kListener, 0)
		        If rc <> 122 Then Exit
		      Next
		      If rc <> 0 Then Continue

		      mb.LittleEndian = True
		      Var n As Integer = mb.UInt32Value(0)
		      For i As Integer = 0 To n - 1
		        Var off As Integer = 4 + i * rowSize
		        ' The port is in network byte order in the low 16 bits.
		        Var port As Integer = mb.Byte(off + portOff) * 256 + mb.Byte(off + portOff + 1)
		        Var pid As Integer = mb.UInt32Value(off + pidOff)
		        ' One port can have several owners on different addresses (sshd on loopback,
		        ' tailscaled on the tailnet IP for :22), so list every distinct one.
		        If Not names.HasKey(pid) And Not mRetook Then
		          mNames = ProcessNames
		          mNamesAt = DateTime.Now
		          names = mNames
		          mRetook = True
		        End If
		        Var name As String = names.Lookup(pid, "pid " + pid.ToString)
		        Var have As String = ", " + result.Lookup(port, "").StringValue + ", "
		        If Not result.HasKey(port) Then
		          result.Value(port) = name
		        ElseIf have.IndexOf(", " + name + ", ") < 0 Then
		          result.Value(port) = result.Value(port).StringValue + ", " + name
		        End If
		      Next
		    Next
		  #EndIf
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ProcessNames() As Dictionary
		  ' pid -> exe name for every process, from one Toolhelp snapshot. Unlike OpenProcess
		  ' this also names SYSTEM services (tailscaled, svchost) without elevation.
		  Var names As New Dictionary
		  names.Value(0) = "Idle"
		  names.Value(4) = "System"
		  #If TargetWindows
		    Declare Function CreateToolhelp32Snapshot Lib "kernel32" (flags As UInt32, pid As UInt32) As Ptr
		    Declare Function Process32FirstW Lib "kernel32" (snap As Ptr, entry As Ptr) As Int32
		    Declare Function Process32NextW Lib "kernel32" (snap As Ptr, entry As Ptr) As Int32
		    Declare Function CloseHandle Lib "kernel32" (h As Ptr) As Int32
		    Const kSnapProcess = 2
		    Var snap As Ptr = CreateToolhelp32Snapshot(kSnapProcess, 0)
		    If snap = Nil Or Integer(snap) = -1 Then Return names
		    ' PROCESSENTRY32W on x64: 568 bytes, pid at 8, szExeFile (UTF-16) at 44.
		    Var e As New MemoryBlock(568)
		    e.LittleEndian = True
		    e.UInt32Value(0) = e.Size
		    Var ok As Int32 = Process32FirstW(snap, e)
		    While ok <> 0
		      Var pid As Integer = e.UInt32Value(8)
		      names.Value(pid) = e.WString(44)
		      ok = Process32NextW(snap, e)
		    Wend
		    Call CloseHandle(snap)
		  #EndIf
		  Return names
		End Function
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mNames As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mNamesAt As DateTime
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRetook As Boolean
	#tag EndProperty


End Module
#tag EndModule
