; reference: https://github.com/Jim-VxE/AHK-Lib-JSON_ToObj
/*
LIB LICENSE

AutoHotkey Object conversion to/from JSON-like text. Copyright © 2011-2012 [VxE]. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that
the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the
following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with the distribution.

3. The name "VxE" may not be used to endorse or promote products derived from this software without specific
prior written permission.

THIS SOFTWARE IS PROVIDED BY VxE "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
SHALL VxE BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
THE POSSIBILITY OF SUCH DAMAGE.
*/

Class JSON
{
	FromObj( obj )
	{
		If IsObject( obj )
		{
			isarray := 0 ; an empty object could be an array... but it ain't, says I
			for key in obj
			{
				if ( key != ++isarray )
				{
					isarray := 0
					Break
				}
			}
			for key, val in obj
			{
				str .= ( A_Index = 1 ? "" : "," ) ( isarray ? "" : this.FromObj( key ) ":" ) this.FromObj( val )
			}
			return isarray ? "[" str "]" : "{" str "}"
		}
		else if obj is Number ;(fstype(obj) == "Integer" or fstype(obj) == "Float")
		{
			return obj
		}

		;	else if obj IN null,true,false ; AutoHotkey does not natively distinguish these
		;		return obj
		; Encode control characters, starting with backslash.
		StringReplace, obj, obj, \, \\, A
		StringReplace, obj, obj, % Chr(08), \b, A
		StringReplace, obj, obj, % A_Tab, \t, A
		StringReplace, obj, obj, `n, \n, A
		StringReplace, obj, obj, % Chr(12), \f, A
		StringReplace, obj, obj, `r, \r, A
		StringReplace, obj, obj, ", \", A
		StringReplace, obj, obj, /, \/, A
		While RegexMatch( obj, "[^\x20-\x7e]", key )
		{
			str := Asc( key )
			val := "\u" . Chr( ( ( str >> 12 ) & 15 ) + ( ( ( str >> 12 ) & 15 ) < 10 ? 48 : 55 ) )
					. Chr( ( ( str >> 8 ) & 15 ) + ( ( ( str >> 8 ) & 15 ) < 10 ? 48 : 55 ) )
					. Chr( ( ( str >> 4 ) & 15 ) + ( ( ( str >> 4 ) & 15 ) < 10 ? 48 : 55 ) )
					. Chr( ( str & 15 ) + ( ( str & 15 ) < 10 ? 48 : 55 ) )
			StringReplace, obj, obj, % key, % val, A
		}
		return """" obj """"
	}

	ToObj( str )
	{
		batch := A_BatchLines
		SetBatchLines, -1
		quot := """" ; firmcoded specifically for readability. Hardcode for (minor) performance gain
		ws := "`t`n`r " Chr(160) ; whitespace plus NBSP. This gets trimmed from the markup
		obj := {} ; dummy object
		objs := [] ; stack
		keys := [] ; stack
		isarrays := [] ; stack
		literals := [] ; queue
		y := nest := 0

		; First pass swaps out literal strings so we can parse the markup easily
		StringGetPos, z, str, %quot% ; initial seek
		while !ErrorLevel
		{
			; Look for the non-literal quote that ends this string. Encode literal backslashes as '\u005C' because the
			; '\u..' entities are decoded last and that prevents literal backslashes from borking normal characters
			StringGetPos, x, str, %quot%,, % z + 1
			while !ErrorLevel
			{
				StringMid, key, str, z + 2, x - z - 1
				StringReplace, key, key, \\, \u005C, A
				If SubStr( key, 0 ) != "\"
					Break
				StringGetPos, x, str, %quot%,, % x + 1
			}
		;	StringReplace, str, str, %quot%%t%%quot%, %quot% ; this might corrupt the string
			str := ( z ? SubStr( str, 1, z ) : "" ) quot SubStr( str, x + 2 ) ; this won't

		; Decode entities
			StringReplace, key, key, \%quot%, %quot%, A
			StringReplace, key, key, \b, % Chr(08), A
			; StringReplace, key, key, \t, % A_Tab, A
			StringReplace, key, key, \n, `n, A
			StringReplace, key, key, \f, % Chr(12), A
			; StringReplace, key, key, \r, `r, A simple replace is far from right parse
			StringReplace, key, key, \/, /, A
			while y := InStr( key, "\u", 0, y + 1 )
			{
				if ( A_IsUnicode || Abs( "0x" SubStr( key, y + 2, 4 ) ) < 0x100 )
				{
					key := ( y = 1 ? "" : SubStr( key, 1, y - 1 ) ) Chr( "0x" SubStr( key, y + 2, 4 ) ) SubStr( key, y + 6 )
				}
			}

			literals.insert(key)
			StringGetPos, z, str, %quot%,, % z + 1 ; seek
		}

		; Second pass parses the markup and builds the object iteratively, swapping placeholders as they are encountered
		key := isarray := 1

		; The outer loop splits the blob into paths at markers where nest level decreases
		Loop Parse, str, % "]}"
		{
			StringReplace, str, A_LoopField, [, [], A ; mark any array open-brackets

			; This inner loop splits the path into segments at markers that signal nest level increases
			Loop Parse, str, % "[{"
			{
				; The first segment might contain members that belong to the previous object
				; Otherwise, push the previous object and key to their stacks and start a new object
				if ( A_Index != 1 )
				{
					objs.insert( obj )
					isarrays.insert( isarray )
					keys.insert( key )
					obj := {}
					isarray := key := Asc( A_LoopField ) = 93
				}
				; arrrrays are made by pirates and they have index keys
				if ( isarray )
				{
					Loop Parse, A_LoopField, `,, % ws "]"
						if ( A_LoopField != "" )
							obj[key++] := A_LoopField = quot ? literals.remove(1) : A_LoopField
				}
				; otherwise, parse the segment as key/value pairs
				else
				{
					Loop Parse, A_LoopField, `,
						Loop Parse, A_LoopField, :, % ws
							if ( A_Index = 1 )
								key := A_LoopField = quot ? literals.remove(1) : A_LoopField
							else if ( A_Index = 2 && A_LoopField != "" )
								obj[key] := A_LoopField = quot ? literals.remove(1) : A_LoopField
				}
				nest += A_Index > 1
			} ; Loop Parse, str, % "[{"

			If !--nest
				Break

			; Insert the newly closed object into the one on top of the stack, then pop the stack
			pbj := obj
			obj := objs.remove()
			obj[key := keys.remove()] := pbj
			If ( isarray := isarrays.remove() )
				key++
		} ; Loop Parse, str, % "]}"
		SetBatchLines, % batch
		Return obj
	} ; json_toobj( str )
}
