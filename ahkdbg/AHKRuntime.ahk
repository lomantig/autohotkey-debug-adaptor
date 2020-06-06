#Include <protocolserver>
#Include <DBGp>
#Include <event>

class AHKRunTime
{
	__New()
	{
		this.dbgAddr := "127.0.0.1"
		this.dbgPort := 9005 ;temp mock debug port
		this.bIsAttach := false
		this.dbgCaptureStreams := false
		RegRead, ahkpath, HKEY_CLASSES_ROOT\AutoHotkeyScript\DefaultIcon
		this.AhkExecutable := SubStr(ahkpath, 1, -2)
		this.Dbg_Session := ""
		this.Dbg_BkList := {}
		this.dbgMaxChildren := 10+0
		this.currline := 0
		this.isStart := false
		this.stopForBreak := true
	}

	Init(clientArgs)
	{
		; Set the DBGp event handlers
		DBGp_OnBegin(ObjBindMethod(this, "OnDebuggerConnection"))
		DBGp_OnBreak(ObjBindMethod(this, "OnDebuggerBreak"))
		DBGp_OnStream(ObjBindMethod(this, "OnDebuggerStream"))
		DBGp_OnEnd(ObjBindMethod(this, "OnDebuggerDisconnection"))
		this.clientArgs := clientArgs
		; DebuggerInit
	}

	Start(path, noDebug := false)
	{
		; Ensure that some important constants exist
		this.path := path, szFilename := path,AhkExecutable := this.AhkExecutable ? this.AhkExecutable : "C:\Program Files\AutoHotkey\AutoHotkey.exe"
		dbgAddr := this.dbgAddr, dbgPort := this.dbgPort ? this.dbgPort : 9005
		SplitPath, szFilename,, szDir

		if noDebug
		{
			Run, "%AhkExecutable%" "%szFilename%", %szDir%
			this.DBGp_CloseDebugger(true)
			this.SendEvent(CreateTerminatedEvent())
			return
		}

		; Now really run AutoHotkey and wait for it to connect
		this.Dbg_Socket := DBGp_StartListening(dbgAddr, dbgPort) ; start listening
		; DebugRun
		Run, "%AhkExecutable%" /Debug=%dbgAddr%:%dbgPort% "%szFilename%", %szDir%,, Dbg_PID ; run AutoHotkey and store its process ID
		this.Dbg_PID := Dbg_PID

		while ((Dbg_AHKExists := Util_ProcessExist(Dbg_PID)) && this.Dbg_Session == "") ; wait for AutoHotkey to connect or exit
			Sleep, 100 ; avoid smashing the CPU
		DBGp_StopListening(this.Dbg_Socket) ; stop accepting script connection
		this.isStart := true
	}

	GetPath()
	{
		SplitPath, % this.path,, dir
		return StrReplace(dir, "\", "\\")
	}

	GetBaseFile()
	{
		SplitPath, % this.path, name
		return name
	}

	Continue()
	{
		this.Run()
	}

	StepIn()
	{
		ErrorLevel = 0
		this.Dbg_OnBreak := false
		this.Dbg_HasStarted := true
		this.stopForBreak := false
		this.Dbg_Session.step_into()
	}

	Next()
	{
		ErrorLevel = 0
		this.Dbg_OnBreak := false
		this.Dbg_HasStarted := true
		this.stopForBreak := false
		this.Dbg_Session.step_over()
	}

	StepOut()
	{
		ErrorLevel = 0
		this.Dbg_OnBreak := false
		this.Dbg_HasStarted := true
		this.stopForBreak := false
		this.Dbg_Session.step_out()
	}

	Run()
	{
		ErrorLevel = 0
		this.Dbg_OnBreak := false
		this.Dbg_HasStarted := true
		this.Dbg_Session.run()
	}

	StartRun(stopOnEntry := false)
	{
		this.VerifyBreakpoints()
		if stopOnEntry
		{
			this.StepIn()
			; FIXME: don't hardcore thread id
			this.SendEvent(CreateStoppedEvent("entry", 1))
		}
		else
			this.Run()
	}

	Pause()
	{
		this.stopForBreak := false
		this.Dbg_Session.Send("break", "", Func("DummyCallback"))
	}

	Dbg_GetStack()
	{
		if !this.Dbg_OnBreak && !this.bIsAsync
			return
		this.Dbg_Session.stack_get("", Dbg_Stack := "")
		this.Dbg_Stack := loadXML(Dbg_Stack)
	}

	; DBGp_CloseDebugger() - used to close the debugger
	DBGp_CloseDebugger(force := 0)
	{
		if !this.bIsAsync && !force && !this.Dbg_OnBreak
		{
			MsgBox, 52, % this.path ", The script is running. Stopping it would mean loss of data. Proceed?"
			IfMsgBox, No
				return 0 ; fail
		}
		DBGp_OnEnd("") ; disable the DBGp OnEnd handler
		if this.bIsAsync || this.Dbg_OnBreak
		{
			; If we're on a break or the debugger is async we don't need to force the debugger to terminate
			this.Dbg_Session.stop()
				; throw Exception("Debug session stop fail.", -1)
			this.Dbg_Session.Close()
		}else ; nope, we're not on a break, kill the process
		{
			this.Dbg_Session.Close()
			Process, Close, %Dbg_PID%
		}
		this.Dbg_Session := ""
		return 1 ; success
	}

	; OnDebuggerConnection() - fired when we receive a connection.
	OnDebuggerConnection(session, init)
	{
		; may need another param to pass the instance of object this function will bind to.
		if this.bIsAttach
			szFilename := session.File
		this.Dbg_Session := session ; store the session ID in a global variable
		dom := loadXML(init)
		this.Dbg_Lang := dom.selectSingleNode("/init/@language").text
		session.property_set("-n A_DebuggerName -- " DBGp_Base64UTF8Encode(this.clientArgs.clientID))
		session.feature_set("-n max_data -v " this.dbgMaxData)
		this.SetEnableChildren(false)
		if this.dbgCaptureStreams
		{
			session.stdout("-c 2")
			session.stderr("-c 2")
		}
		session.feature_get("-n supports_async", response)
		this.bIsAsync := !!InStr(response, ">1<")
		; Really nothing more to do
	}

	; OnDebuggerBreak() - fired when we receive an asynchronous response from the debugger (including break responses).
	OnDebuggerBreak(session, ByRef response)
	{
		global Dbg_OnBreak, Dbg_Stack, Dbg_LocalContext, Dbg_GlobalContext, Dbg_VarWin, bInBkProcess, _tempResponse

		if this.bInBkProcess
		{
			; A breakpoint was hit while the script running and the SciTE OnMessage thread is
			; still running. In order to avoid crashing, we must delay this function's processing
			; until the OnMessage thread is finished.
			ODB := ObjBindMethod(this, "OnDebuggerBreak")
			EventDispatcher.PutDelay(ODB, [session, response])
			return
		}
		response := response ? response : _tempResponse
		dom := loadXML(response) ; load the XML document that the variable response is
		status := dom.selectSingleNode("/response/@status").text ; get the status
		if status = break
		{ ; this is a break response
			this.Dbg_OnBreak := true ; set the Dbg_OnBreak variable
			; Get info about the script currently running
			this.Dbg_GetStack()
			; Check if we are stopped because of hitting a breakpoint
			if this.stopForBreak
				this.SendEvent(CreateStoppedEvent("breakpoint", DebugSession.THREAD_ID))
			this.stopForBreak := true
		}
	}

	; OnDebuggerStream() - fired when we receive a stream packet.
	OnDebuggerStream(session, ByRef stream)
	{
		dom := loadXML(stream)
		type := dom.selectSingleNode("/stream/@type").text
		data := DBGp_Base64UTF8Decode(dom.selectSingleNode("/stream").text)
		; Send output event
		this.SendEvent(CreateOutputEvent(type, data))
	}

	; OnDebuggerDisconnection() - fired when the debugger disconnects.
	OnDebuggerDisconnection(session)
	{
		global
		Critical

		Dbg_ExitByDisconnect := true ; tell our message handler to just return true without attempting to exit
		Dbg_ExitByGuiClose := true
		Dbg_IsClosing := true
		Dbg_OnBreak := true
		this.SendEvent(CreateTerminatedEvent())
	}

	clearBreakpoints(path)
	{
		uri := DBGp_EncodeFileURI(path)
		for line, bk in this.Dbg_BkList[uri]
			this.Dbg_Session.breakpoint_remove("-d " bk.id)
		; MsgBox, % line " " fsarr().Print(bk)
		this.Dbg_BkList[uri] := {}
		; this.Dbg_Session.breakpoint_list(, Dbg_Response)
		; MsgBox, % Dbg_Response " " fsarr().Print(this.Dbg_BkList)
	}

	; @line: 1 based lineno
	SetBreakpoint(path, line)
	{
		uri := DBGp_EncodeFileURI(path)
		bk := this.GetBk(uri, line)
		if !this.isStart
			return {"verified": "false", "line": line, "id": bk.id}
		
		this.bInBkProcess := true
		this.Dbg_Session.breakpoint_set("-t line -n " line " -f " uri, Dbg_Response)
		If InStr(Dbg_Response, "<error") || !Dbg_Response ; Check if AutoHotkey actually inserted the breakpoint.
		{
			this.bInBkProcess := false
			; TODO: return reason to frontend
			return {"verified": "false", "line": line, "id": ""}
		}

		dom := loadXML(Dbg_Response)
		bkID := dom.selectSingleNode("/response/@id").text
		this.Dbg_Session.breakpoint_get("-d " bkID, Dbg_Response)
		dom := loadXML(Dbg_Response)
		line := dom.selectSingleNode("/response/breakpoint[@id=" bkID "]/@lineno").text
		;remove 'file:///' in begin, make uri format some
		sourceUri := SubStr(dom.selectSingleNode("/response/breakpoint[@id=" bkID "]/@filename").text, 9)
		sourcePath := DBGp_DecodeFileURI(sourceUri)
		this.AddBk(sourceUri, line, bkID)
		this.bInBkProcess := false
		; FIXME: debug
		; this.SendEvent(CreateOutputEvent("stdout",  sourcePath " " path " " line))
		return {"verified": "true", "line": line, "id": bkID, "source": sourcePath}
	}

	VerifyBreakpoints()
	{
		for _, uri in this.Dbg_BkList
		{
			sourcePath := DBGp_DecodeFileURI(uri)
			for line, bk in uri
				this.SendEvent(CreateBreakpointEvent("changed", CreateBreakpoint("true", bk.id, line, , sourcePath)))
		}
	}

	InspectVariable(Dbg_VarName, frameId)
	{
		; Allow retrieving immediate children for object values
		this.SetEnableChildren(true)
		if (frameId != "None")
			this.Dbg_Session.property_get("-n " . Dbg_VarName . " -d " . frameId, Dbg_Response)
		else
		; context id of a global variable is 1
			this.Dbg_Session.property_get("-c 1 -n " Dbg_VarName, Dbg_Response)
		this.SetEnableChildren(false)
		dom := loadXML(Dbg_Response)

		Dbg_NewVarName := dom.selectSingleNode("/response/property/@name").text
		if Dbg_NewVarName = (invalid)
		{
			MsgBox, 48, %g_appTitle%, Invalid variable name: %Dbg_VarName%
			return false
		}
		if ((type := dom.selectSingleNode("/response/property/@type").text) != "Object")
		{
			Dbg_VarIsReadOnly := dom.selectSingleNode("/response/property/@facet").text = "Builtin"
			Dbg_VarData := DBGp_Base64UTF8Decode(dom.selectSingleNode("/response/property").text)
			Dbg_VarData := {"name": Dbg_NewVarName, "value": Dbg_VarData, "type": type}
			;VE_Create(Dbg_VarName, Dbg_VarData, Dbg_VarIsReadOnly)
		}else
			Dbg_VarData := this.InspectObject(dom)

		return Dbg_VarData
	}

	CheckVariables(id, frameId)
	{
		if (id == "Global")
			id := "-c 1"
		else if (id == "Local")
			id := "-d " . frameId . " -c 0"
		else
			return this.InspectVariable(id, frameId)
		; TODO: may need to send error
		; if !this.bIsAsync && !this.Dbg_OnBreak

		this.Dbg_Session.context_get(id, ScopeContext)
		ScopeContext := loadXML(ScopeContext)
		name := Util_UnpackNodes(ScopeContext.selectNodes("/response/property/@name"))
		value := Util_UnpackContNodes(ScopeContext.selectNodes("/response/property"))
		type := Util_UnpackNodes(ScopeContext.selectNodes("/response/property/@type"))
		facet := Util_UnpackNodes(ScopeContext.selectNodes("/response/property/@facet"))

		return {"name": name, "value": value, "type": type, "facet": facet}
	}

	InspectObject(ByRef objdom)
	{
		root := objdom.selectSingleNode("/response/property/@name").text
		propertyNodes := objdom.selectNodes("/response/property[1]/property")
		
		name := [], value := [], type := []
		
		Loop % propertyNodes.length
		{
			node := propertyNodes.item[A_Index-1]
			nodeName := node.attributes.getNamedItem("name").text
			needToLoadChildren := node.attributes.getNamedItem("children").text
			fullName := node.attributes.getNamedItem("fullname").text
			nodeType := node.attributes.getNamedItem("type").text
			nodeValue := DBGp_Base64UTF8Decode(node.text)
			name.Push(fullName), type.Push(nodeType), value.Push(nodeValue)
		}
		; TODO: better display name
		return {"name": name, "value": value, "type": type}
	}

	SetVariable(varFullName, frameId, value)
	{	
		if (frameId != "None")
			cmd := "-n " varFullName " -d " frameId " -- "
		else
		; context id of a global variable is 1
			cmd := "-c 1 -n " varFullName " -- "

		this.Dbg_Session.property_set(cmd . DBGp_Base64UTF8Encode(value), Dbg_Response)
		if !InStr(Dbg_Response, "success=""1""")
			throw Exception("Set fail!", -1, "Variable may be immutable.")
		return this.InspectVariable(varFullName, frameId)
	}

	SetEnableChildren(v)
	{
		Dbg_Session := this.Dbg_Session
		dbgMaxChildren := this.dbgMaxChildren
		if v
		{
			Dbg_Session.feature_set("-n max_children -v " dbgMaxChildren)
			Dbg_Session.feature_set("-n max_depth -v 1")
		}else
		{
			Dbg_Session.feature_set("-n max_children -v 0")
			Dbg_Session.feature_set("-n max_depth -v 0")
		}
	}

	GetStack()
	{
		aStackWhere := Util_UnpackNodes(this.Dbg_Stack.selectNodes("/response/stack/@where"))
		aStackFile  := Util_UnpackNodes(this.Dbg_Stack.selectNodes("/response/stack/@filename"))
		aStackLine  := Util_UnpackNodes(this.Dbg_Stack.selectNodes("/response/stack/@lineno"))
		aStackLevel := Util_UnpackNodes(this.Dbg_Stack.selectNodes("/response/stack/@level"))
		Loop, % aStackFile.Length()
			aStackFile[A_Index] := DBGp_DecodeFileURI(aStackFile[A_Index])

		return {"file": aStackFile, "line": aStackLine, "where": aStackWhere, "level": aStackLevel}
	}

	GetStackDepth()
	{
		this.Dbg_Session.stack_depth( , Dbg_Response)
		startpos := InStr(Dbg_Response, "depth=""")+7
		, depth := SubStr(Dbg_Response, startpos, InStr(Dbg_Response,"""", ,startpos) - startpos)
		return depth
	}

	GetScopeNames()
	{
		if this.Dbg_Session.context_names("", response) != 0
			throw Exception("Xdebug error", -1, ErrorLevel)
		dom := loadXML(response)
		contexts := dom.selectNodes("/response/context/@name")
		scopes := []
		Loop % contexts.length
		{
			context := contexts.item[A_Index-1].text
			scopes.Push(context)
		}
		return scopes
	}

	AddBk(uri, line, id, cond := "")
	{
		this.Dbg_BkList[uri, line] := { "id": id, "cond": cond }
	}

	GetBk(uri, line)
	{
		return this.Dbg_BkList[uri, line]
	}

	RemoveBk(uri, line)
	{
		this.Dbg_BkList[uri].Delete(line)
	}

	SendEvent(event)
	{
		EventDispatcher.EmitImmediately("sendEvent", event)
	}

	__Delete()
	{
		DBGp_StopListening(this.Dbg_Socket)
		this.DBGp_CloseDebugger()
		if Util_ProcessExist(this.Dbg_PID)
			Process, Close, % this.Dbg_PID
	}
}

; //////////////////////// Util Function ///////////////////////
Util_ProcessExist(a)
{
	t := ErrorLevel
	Process, Exist, %a%
	r := ErrorLevel
	ErrorLevel := t
	return r
}

Util_UnpackNodes(nodes)
{
	o := []
	Loop, % nodes.length
		o.Insert(nodes.item[A_Index-1].text)
	return o
}

Util_UnpackContNodes(nodes)
{
	o := []
	Loop, % nodes.length
		node := nodes.item[A_Index-1]
		,o.Insert(node.attributes.getNamedItem("type").text != "object" ? DBGp_Base64UTF8Decode(node.text) : "(Object)")
	return o
}

ST_ShortName(a)
{
	SplitPath, a, b
	return b
}

loadXML(ByRef data)
{
	o := ComObjCreate("MSXML2.DOMDocument")
	o.async := false
	o.setProperty("SelectionLanguage", "XPath")
	o.loadXML(data)
	return o
}

DummyCallback(session, ByRef response)
{

}
