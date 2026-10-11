module [decode, encode]

# The compiler supplies semantic tag information, independent of this protocol.
Response : {
	result : Str,
	stdout : Str,
	diagnostics : Str,
	value : [Other, Tag({ name : Str, payload : Try(Str, {}) })],
}

decode : Str -> Try(Str, Str)
decode = |line| {
	request : Try({ code : Str }, [InvalidJson(Str), MissingRequiredField(Str)])
	request = Json.parse(line)
	match request {
		Ok({ code }) => Ok(code)
		Err(problem) => Err(encode({ result: "", stdout: "", diagnostics: Str.inspect(problem), value: Other }))
	}
}

encode : Response -> Str
encode = |response| {
	rich = match response.value {
		Other => Ok([])
		Tag({ name, payload }) => {
			format = match name {
				"Html" => Ok(("text/html", "text"))
				"Markdown" => Ok(("text/markdown", "text"))
				"Svg" => Ok(("image/svg+xml", "text"))
				"Json" => Ok(("application/json", "json"))
				_ => Err({})
			}
			match format {
				Err({}) => Ok([])
				Ok((mime, encoding)) => match payload {
					Ok(value) => Ok([{ mime, encoding, value }])
					Err({}) => Err("${name} expects exactly one Str payload")
				}
			}
		}
	}
	reply = match rich {
		Ok(data) => { result: response.result, stdout: response.stdout, diagnostics: response.diagnostics, data }
		Err(problem) => { result: response.result, stdout: response.stdout, diagnostics: if response.diagnostics.is_empty() problem else response.diagnostics, data: [] }
	}
	Json.to_str(reply)
}
