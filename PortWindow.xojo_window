#tag DesktopWindow
Begin DesktopWindow PortWindow
   Backdrop        =   0
   BackgroundColor =   &cFFFFFF
   Composite       =   False
   DefaultLocation =   2
   FullScreen      =   False
   HasBackgroundColor=   False
   HasCloseButton  =   True
   HasFullScreenButton=   False
   HasMaximizeButton=   False
   HasMinimizeButton=   False
   HasTitleBar     =   True
   Height          =   150
   ImplicitInstance=   False
   MacProcID       =   0
   MaximumHeight   =   32000
   MaximumWidth    =   32000
   MenuBar         =   0
   MenuBarVisible  =   False
   MinimumHeight   =   150
   MinimumWidth    =   360
   Resizeable      =   False
   Title           =   "Change port"
   Type            =   1
   Visible         =   True
   Width           =   360
End
#tag EndDesktopWindow

#tag WindowCode
	#tag Event
		Sub Opening()
		  ' Built in code like the preferences window. OK writes the new port into
		  ' services.json (App.SetServicePort); its URLs that named the old port follow.
		  Var l As New DesktopLabel
		  l.Text = "Port for " + mName + If(mOld > 0, " (now " + mOld.ToString + ")", "") + ":"
		  l.Left = 20
		  l.Top = 20
		  l.Width = 320
		  l.Height = 20
		  Self.AddControl(l)

		  mField = New DesktopTextField
		  mField.Left = 20
		  mField.Top = 46
		  mField.Width = 90
		  mField.Height = 24
		  mField.Text = If(mSuggest > 0, mSuggest.ToString, If(mOld > 0, mOld.ToString, ""))
		  Self.AddControl(mField)

		  If mSuggest > 0 Then
		    Var hint As New DesktopLabel
		    hint.Text = "Its process is listening on " + mSuggest.ToString + "."
		    hint.Left = 122
		    hint.Top = 49
		    hint.Width = 220
		    hint.Height = 20
		    hint.FontSize = 11
		    hint.TextColor = &c80808000
		    Self.AddControl(hint)
		  End If

		  mOK = New DesktopButton
		  mOK.Caption = "OK"
		  mOK.Default = True
		  mOK.Left = 160
		  mOK.Top = 100
		  mOK.Width = 85
		  mOK.Height = 26
		  Self.AddControl(mOK)
		  AddHandler mOK.Pressed, WeakAddressOf OKPressed

		  mCancel = New DesktopButton
		  mCancel.Caption = "Cancel"
		  mCancel.Cancel = True
		  mCancel.Left = 255
		  mCancel.Top = 100
		  mCancel.Width = 85
		  mCancel.Height = 26
		  Self.AddControl(mCancel)
		  AddHandler mCancel.Pressed, WeakAddressOf CancelPressed

		  mField.SetFocus
		  mField.SelectAll
		End Sub
	#tag EndEvent


	#tag Method, Flags = &h21
		Private Sub CancelPressed(sender As DesktopButton)
		  #Pragma Unused sender
		  Chosen = 0
		  Self.Close
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OKPressed(sender As DesktopButton)
		  #Pragma Unused sender
		  Var p As Integer = mField.Text.Trim.ToInteger
		  If p < 1 Or p > 65535 Then
		    System.Beep
		    mField.SetFocus
		    Return
		  End If
		  Chosen = p
		  Self.Close
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub Prepare(name As String, oldPort As Integer, suggest As Integer)
		  mName = name
		  mOld = oldPort
		  mSuggest = suggest
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h0
		Chosen As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCancel As DesktopButton
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mField As DesktopTextField
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mName As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mOK As DesktopButton
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mOld As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSuggest As Integer
	#tag EndProperty


#tag EndWindowCode
