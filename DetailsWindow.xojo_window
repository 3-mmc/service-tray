#tag DesktopWindow
Begin DesktopWindow DetailsWindow
   Backdrop        =   0
   BackgroundColor =   &cFFFFFF
   Composite       =   False
   DefaultLocation =   2
   FullScreen      =   False
   HasBackgroundColor=   False
   HasCloseButton  =   True
   HasFullScreenButton=   False
   HasMaximizeButton=   True
   HasMinimizeButton=   True
   HasTitleBar     =   True
   Height          =   600
   ImplicitInstance=   False
   MacProcID       =   0
   MaximumHeight   =   32000
   MaximumWidth    =   32000
   MenuBar         =   0
   MenuBarVisible  =   False
   MinimumHeight   =   240
   MinimumWidth    =   560
   Resizeable      =   True
   Title           =   "ServiceTray"
   Type            =   0
   Visible         =   True
   Width           =   980
End
#tag EndDesktopWindow

#tag WindowCode
	#tag Event
		Sub Closing()
		  App.DetailsClosed
		End Sub
	#tag EndEvent

	#tag Event
		Sub Opening()
		  ' Controls are made in code, so this file stays small and hand-editable.
		  mButtonTags = New Dictionary
		  mSummaryLabel = New DesktopLabel
		  mSummaryLabel.Left = 12
		  mSummaryLabel.Top = 14
		  mSummaryLabel.Width = Self.Width - 24 - 3 * 112
		  mSummaryLabel.Height = 20
		  mSummaryLabel.LockLeft = True
		  mSummaryLabel.LockRight = True
		  mSummaryLabel.LockTop = True
		  Self.AddControl(mSummaryLabel)

		  Var captions() As String = Array("Refresh", "Check ports", "Edit config")
		  Var tags() As String = Array("refresh", "checkports", "edit")
		  For i As Integer = 0 To captions.LastIndex
		    Var b As New DesktopButton
		    b.Caption = captions(i)
		    b.Width = 104
		    b.Height = 26
		    b.Top = 10
		    b.Left = Self.Width - 12 - (captions.Count - i) * 112 + 8
		    b.LockLeft = False
		    b.LockRight = True
		    b.LockTop = True
		    mButtonTags.Value(b) = tags(i)
		    AddHandler b.Pressed, WeakAddressOf ButtonPressed
		    Self.AddControl(b)
		  Next

		  mList = New DesktopListBox
		  mList.Left = 12
		  mList.Top = 46
		  mList.Width = Self.Width - 24
		  mList.Height = Self.Height - 58
		  mList.LockLeft = True
		  mList.LockRight = True
		  mList.LockTop = True
		  mList.LockBottom = True
		  mList.ColumnCount = 6
		  mList.HasHeader = True
		  mList.ColumnWidths = "210,100,70,80,260,*"
		  mList.DefaultRowHeight = 24
		  AddHandler mList.DoublePressed, WeakAddressOf ListDoublePressed
		  AddHandler mList.PaintCellText, WeakAddressOf ListPaintCellText
		  AddHandler mList.ConstructContextualMenu, WeakAddressOf ListContextMenu
		  AddHandler mList.ContextualMenuItemSelected, WeakAddressOf ListContextChosen
		  AddHandler mList.HeaderPressed, WeakAddressOf ListHeaderPressed
		  Self.AddControl(mList)
		  ' Headers only stick once the control is on the window.
		  Var heads() As String = Array("Service", "Status", "Port", "Side", "Owner", "Detail")
		  For i As Integer = 0 To heads.LastIndex
		    mList.HeaderAt(i) = heads(i)
		  Next
		  ' Opening runs after the App's first Reload call, so fill the list here too.
		  Reload
		End Sub
	#tag EndEvent


	#tag Method, Flags = &h21
		Private Sub ButtonPressed(sender As DesktopButton)
		  App.DoAction(mButtonTags.Lookup(sender, "").StringValue)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function KeyAt(row As Integer) As String
		  If row < 0 Or row >= mList.RowCount Then Return ""
		  Var d As Dictionary = mList.RowTagAt(row)
		  If d = Nil Then Return ""
		  Return d.Value("key").StringValue
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ListContextChosen(sender As DesktopListBox, selectedItem As DesktopMenuItem) As Boolean
		  #Pragma Unused sender
		  If selectedItem <> Nil And selectedItem.Tag <> Nil Then App.DoAction(selectedItem.Tag.StringValue)
		  Return True
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ListContextMenu(sender As DesktopListBox, base As DesktopMenuItem, x As Integer, y As Integer) As Boolean
		  ' Right-click acts on the row under the mouse, with the same actions as the tray.
		  Var row As Integer = sender.RowFromXY(x, y)
		  Var key As String = KeyAt(row)
		  If key = "" Then Return False
		  sender.SelectedRowIndex = row
		  App.FillActions(key, base)
		  Return base.Count > 0
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ListHeaderPressed(sender As DesktopListBox, column As Integer) As Boolean
		  #Pragma Unused sender
		  #Pragma Unused column
		  ' Sorting would scatter the group rows, so header clicks do nothing.
		  Return True
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ListDoublePressed(sender As DesktopListBox)
		  Var key As String = KeyAt(sender.SelectedRowIndex)
		  If key <> "" Then App.DefaultAction(key)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ListPaintCellText(sender As DesktopListBox, g As Graphics, row As Integer, column As Integer, x As Integer, y As Integer) As Boolean
		  Var d As Dictionary = sender.RowTagAt(row)
		  If d = Nil Then Return False
		  Var kind As String = d.Value("kind").StringValue
		  If kind = "group" Then
		    ' Section rows: bold name, the rollup in grey beside it.
		    g.Bold = (column = 0)
		    g.DrawingColor = If(column = 0, TextColor, &c80808000)
		    g.DrawText(sender.CellTextAt(row, column), x, y)
		    Return True
		  End If
		  If kind = "sub" Then
		    ' Category labels stay quiet: grey italic, no status.
		    g.Italic = True
		    g.DrawingColor = &c80808000
		    g.DrawText(sender.CellTextAt(row, column), x, y)
		    Return True
		  End If
		  If column = 1 Then
		    ' Status: a coloured dot, then the word.
		    Var st As Integer = d.Value("status").IntegerValue
		    Var c As Color = &c7F8C8D00
		    Select Case st
		    Case App.kStUp
		      c = &c27AE6000
		    Case App.kStDegraded
		      c = &cE67E2200
		    Case App.kStDown
		      c = &cC0392B00
		    Case App.kStEphemeral
		      c = &c2E86DE00
		    End Select
		    Var h As Integer = g.TextHeight
		    g.DrawingColor = c
		    g.FillOval(x, y - h + 4, 9, 9)
		    g.DrawingColor = TextColor
		    g.DrawText(sender.CellTextAt(row, column), x + 15, y)
		    Return True
		  End If
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function TextColor() As Color
		  Return If(Color.IsDarkMode, &cE0E0E000, &c20202000)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub Reload()
		  ' Rebuilt only when the app's state text changed, keeping selection and scroll.
		  If mList = Nil Then Return
		  Var keep As String = KeyAt(mList.SelectedRowIndex)
		  Var scroll As Integer = mList.ScrollPosition
		  mList.RemoveAllRows
		  Var sel As Integer = -1
		  For Each d As Dictionary In App.DetailRows
		    Var cells() As String = d.Value("cells")
		    mList.AddRow(cells)
		    mList.RowTagAt(mList.LastAddedRowIndex) = d
		    If keep <> "" And d.Value("key").StringValue = keep Then sel = mList.LastAddedRowIndex
		  Next
		  If sel >= 0 Then mList.SelectedRowIndex = sel
		  mList.ScrollPosition = scroll
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub SetSummary(text As String)
		  If mSummaryLabel <> Nil And mSummaryLabel.Text <> text Then mSummaryLabel.Text = text
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mButtonTags As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mList As DesktopListBox
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSummaryLabel As DesktopLabel
	#tag EndProperty


#tag EndWindowCode
