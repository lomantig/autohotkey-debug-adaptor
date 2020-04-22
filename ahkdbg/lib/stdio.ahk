class StdIO
{
	__New()
	{
		this.inStream := FileOpen("*", "r")
		; this.outStream := FileOpen("*", "w", "utf-8")
	}

	Read()
	{
		return this.inStream.Read()
		; FileRead, r, *
		; return r
	}

	Write(text)
	{
		; Some problem in call write method of outStream
		; Raw write to stdout by fileappend
		FileAppend, % text, *
		; outStream := FileOpen("*", "w `n", "utf-8")
		; VarSetCapacity(ps, StrLen(text)*3, 0)
		; Capacity := StrPut(text, &ps, "utf-8")
		; StrPut(text, &ps, Capacity, "utf-8")
		; outStream.RawWrite(&ps, Capacity-1)
		; outStream.Close()
		; outStream.Write(&ps)
	}

	__Delete()
	{
		this.inStream.Close()
	}
}
