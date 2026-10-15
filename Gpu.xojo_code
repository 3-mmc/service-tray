#tag Module
Protected Module Gpu
	#tag Method, Flags = &h0
		Function ReadVram(ByRef usedMiB As Integer, ByRef totalMiB As Integer) As Boolean
		  ' VRAM of GPU 0 straight from nvml.dll (ships with the NVIDIA driver), replacing
		  ' LlamaTray's nvidia-smi process every 3 s with an in-process call.
		  #If TargetWindows
		    If mFailed Then Return False
		    Soft Declare Function nvmlInit_v2 Lib "nvml.dll" () As Int32
		    Soft Declare Function nvmlDeviceGetHandleByIndex_v2 Lib "nvml.dll" (index As UInt32, ByRef device As Ptr) As Int32
		    Soft Declare Function nvmlDeviceGetMemoryInfo Lib "nvml.dll" (device As Ptr, mem As Ptr) As Int32
		    If Not mReady Then
		      If Not System.IsFunctionAvailable("nvmlInit_v2", "nvml.dll") Or nvmlInit_v2 <> 0 Then
		        mFailed = True
		        Return False
		      End If
		      If nvmlDeviceGetHandleByIndex_v2(0, mDevice) <> 0 Then
		        mFailed = True
		        Return False
		      End If
		      mReady = True
		    End If
		    ' nvmlMemory_t: total, free, used as three UInt64 byte counts.
		    Var mem As New MemoryBlock(24)
		    mem.LittleEndian = True
		    If nvmlDeviceGetMemoryInfo(mDevice, mem) <> 0 Then Return False
		    totalMiB = mem.UInt64Value(0) \ 1048576
		    usedMiB = mem.UInt64Value(16) \ 1048576
		    Return True
		  #Else
		    #Pragma Unused usedMiB
		    #Pragma Unused totalMiB
		    Return False
		  #EndIf
		End Function
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mDevice As Ptr
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mFailed As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mReady As Boolean
	#tag EndProperty


End Module
#tag EndModule
