#tag DesktopWindow
Begin DesktopWindow PrefsWindow
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
   Height          =   300
   ImplicitInstance=   False
   MacProcID       =   0
   MaximumHeight   =   32000
   MaximumWidth    =   32000
   MenuBar         =   0
   MenuBarVisible  =   False
   MinimumHeight   =   300
   MinimumWidth    =   420
   Resizeable      =   False
   Title           =   "ServiceTray Preferences"
   Type            =   0
   Visible         =   True
   Width           =   420
End
#tag EndDesktopWindow

#tag WindowCode
	#tag Event
		Sub Closing()
		  App.PrefsClosed
		End Sub
	#tag EndEvent

	#tag Event
		Sub Opening()
		  ' Built in code like the details window. Every change applies at once and is saved
		  ' to settings.json, so there is no OK button to forget.
		  Var y As Integer = 20
		  Call AddLabel("Sort and group by", 20, y + 3, 140)
		  mSort = New DesktopPopupMenu
		  mSort.Left = 170
		  mSort.Top = y
		  mSort.Width = 220
		  mSort.Height = 24
		  mSort.AddRow("Environment (Windows / WSL)")
		  mSort.AddRow("Category")
		  mSort.AddRow("Port number")
		  mSort.AddRow("Name")
		  Self.AddControl(mSort)

		  y = y + 40
		  mCategories = AddCheck("Show categories under each environment", y)
		  y = y + 30
		  mCollapse = AddCheck("Fold sections where everything is up", y)
		  y = y + 30
		  mHideIdle = AddCheck("Hide optional services that are not running", y)

		  y = y + 44
		  Call AddLabel("Only show ports", 20, y + 3, 140)
		  Call AddLabel("from", 170, y + 3, 36)
		  mFrom = AddField(208, y)
		  Call AddLabel("to", 290, y + 3, 20)
		  mTo = AddField(312, y)
		  y = y + 30
		  Var hint As DesktopLabel = AddLabel("Leave empty for all. Services without a port always show.", 20, y, 380)
		  hint.FontSize = 11
		  hint.TextColor = &c80808000

		  ' Load current values before wiring the handlers, so loading does not count as a change.
		  Var sorts() As String = Array("environment", "category", "port", "name")
		  mSort.SelectedRowIndex = Max(0, sorts.IndexOf(App.Setting("sortBy").StringValue))
		  mCategories.Value = App.Setting("showCategories").BooleanValue
		  mCollapse.Value = App.Setting("collapseHealthy").BooleanValue
		  mHideIdle.Value = App.Setting("hideIdle").BooleanValue
		  If App.Setting("portFrom").IntegerValue > 0 Then mFrom.Text = App.Setting("portFrom").StringValue
		  If App.Setting("portTo").IntegerValue > 0 Then mTo.Text = App.Setting("portTo").StringValue
		  mCategories.Enabled = mSort.SelectedRowIndex = 0

		  AddHandler mSort.SelectionChanged, WeakAddressOf SortChanged
		  AddHandler mCategories.ValueChanged, WeakAddressOf CheckChanged
		  AddHandler mCollapse.ValueChanged, WeakAddressOf CheckChanged
		  AddHandler mHideIdle.ValueChanged, WeakAddressOf CheckChanged
		  AddHandler mFrom.TextChanged, WeakAddressOf FieldChanged
		  AddHandler mTo.TextChanged, WeakAddressOf FieldChanged
		End Sub
	#tag EndEvent


	#tag Method, Flags = &h21
		Private Function AddCheck(caption As String, y As Integer) As DesktopCheckBox
		  Var c As New DesktopCheckBox
		  c.Caption = caption
		  c.Left = 20
		  c.Top = y
		  c.Width = 380
		  c.Height = 22
		  Self.AddControl(c)
		  Return c
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function AddField(x As Integer, y As Integer) As DesktopTextField
		  Var f As New DesktopTextField
		  f.Left = x
		  f.Top = y
		  f.Width = 72
		  f.Height = 24
		  Self.AddControl(f)
		  Return f
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function AddLabel(text As String, x As Integer, y As Integer, w As Integer) As DesktopLabel
		  Var l As New DesktopLabel
		  l.Text = text
		  l.Left = x
		  l.Top = y
		  l.Width = w
		  l.Height = 20
		  Self.AddControl(l)
		  Return l
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub Apply()
		  Var sorts() As String = Array("environment", "category", "port", "name")
		  Var d As New Dictionary
		  d.Value("sortBy") = sorts(Max(0, mSort.SelectedRowIndex))
		  d.Value("showCategories") = mCategories.Value
		  d.Value("collapseHealthy") = mCollapse.Value
		  d.Value("hideIdle") = mHideIdle.Value
		  d.Value("portFrom") = mFrom.Text.Trim.ToInteger
		  d.Value("portTo") = mTo.Text.Trim.ToInteger
		  App.ApplySettings(d)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub CheckChanged(sender As DesktopCheckBox)
		  #Pragma Unused sender
		  Apply
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub FieldChanged(sender As DesktopTextField)
		  #Pragma Unused sender
		  Apply
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub SortChanged(sender As DesktopPopupMenu, item As DesktopMenuItem)
		  #Pragma Unused item
		  ' Category sub-labels only make sense under the environment sort.
		  mCategories.Enabled = sender.SelectedRowIndex = 0
		  Apply
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mCategories As DesktopCheckBox
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCollapse As DesktopCheckBox
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mFrom As DesktopTextField
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHideIdle As DesktopCheckBox
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSort As DesktopPopupMenu
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTo As DesktopTextField
	#tag EndProperty


#tag EndWindowCode
