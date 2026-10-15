#tag Module
Protected Module PortProbe
	#tag Method, Flags = &h0
		Function ExcludedRanges() As Pair()
		  ' Port blocks Windows has reserved (Hyper-V, WinNAT, or netsh add excludedportrange).
		  ' The lines are "  start  end  [*]"; the German headers have no digits in them.
		  Var result() As Pair
		  Var sh As New Shell
		  sh.ExecuteMode = Shell.ExecuteModes.Synchronous
		  sh.Execute("netsh int ipv4 show excludedportrange protocol=tcp")
		  For Each line As String In sh.Result.ReplaceAll(EndOfLine.Windows, EndOfLine.UNIX).ToArray(EndOfLine.UNIX)
		    Var nums() As Integer
		    For Each w As String In line.ToArray(" ")
		      If w <> "" And w.ToInteger > 0 And w.ToInteger.ToString = w Then nums.Add(w.ToInteger)
		    Next
		    If nums.Count = 2 Then result.Add(nums(0) : nums(1))
		  Next
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function WindowsBind(port As Integer) As Integer
		  ' Try to bind 127.0.0.1:port and let go at once. 0 means bindable; otherwise the
		  ' Winsock error: 10013 = access denied (reserved range), 10048 = address in use.
		  ' This is the TcpListener sweep from the llama-swap notes, minus PowerShell.
		  #If TargetWindows
		    Declare Function WSAStartup Lib "ws2_32.dll" (version As UInt16, data As Ptr) As Int32
		    Declare Function NewSocket Lib "ws2_32.dll" Alias "socket" (af As Int32, kind As Int32, proto As Int32) As UInt64
		    Declare Function BindSocket Lib "ws2_32.dll" Alias "bind" (s As UInt64, addr As Ptr, length As Int32) As Int32
		    Declare Function closesocket Lib "ws2_32.dll" (s As UInt64) As Int32
		    Declare Function WSAGetLastError Lib "ws2_32.dll" () As Int32
		    If Not mStarted Then
		      Var wsa As New MemoryBlock(512)
		      Call WSAStartup(&h0202, wsa)
		      mStarted = True
		    End If
		    Var s As UInt64 = NewSocket(2, 1, 6) ' AF_INET, SOCK_STREAM, IPPROTO_TCP
		    If s = &hFFFFFFFFFFFFFFFF Then Return WSAGetLastError
		    ' sockaddr_in: family (LE), port (big-endian), 127.0.0.1, zero padding.
		    Var a As New MemoryBlock(16)
		    a.LittleEndian = True
		    a.UInt16Value(0) = 2
		    a.Byte(2) = port \ 256
		    a.Byte(3) = port Mod 256
		    a.Byte(4) = 127
		    a.Byte(7) = 1
		    Var rc As Integer = 0
		    If BindSocket(s, a, 16) <> 0 Then rc = WSAGetLastError
		    Call closesocket(s)
		    Return rc
		  #Else
		    #Pragma Unused port
		    Return 0
		  #EndIf
		End Function
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mStarted As Boolean
	#tag EndProperty


End Module
#tag EndModule
