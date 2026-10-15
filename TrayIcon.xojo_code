#tag Class
Protected Class TrayIcon
Inherits DesktopTrayItem
	#tag Event
		Sub Pressed(cause As PressedTypes)
		  Select Case cause
		  Case DesktopTrayItem.PressedTypes.DoubleClick
		    App.RefreshNow
		  Else
		    App.ShowMenu
		  End Select
		End Sub
	#tag EndEvent


End Class
#tag EndClass
