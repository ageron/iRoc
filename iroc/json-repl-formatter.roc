module [decode, encode]

Request : [Evaluate(Str), Reply(Str)]

# The compiler supplies semantic tag information, independent of this protocol.
Response : {
	status : [Success, Incomplete, Failure],
	result : Str,
	stdout : Str,
	diagnostics : Str,
	value : [Other, Tag({ name : Str, payload : Try(Str, {}) })],
}

decode : Str -> Request
decode = |line| {
	request : Try({ code : Str }, [InvalidJson(Str), MissingRequiredField(Str)])
	request = Json.parse(line)
	match request {
		Ok({ code }) => Evaluate(code)
		Err(problem) => Reply(encode(line, { status: Failure, result: "", stdout: "", diagnostics: Str.inspect(problem), value: Other }))
	}
}

encode : Str, Response -> Str
encode = |_input, response| {
	status = match response.status {
		Success => "success"
		Incomplete => "incomplete"
		Failure => "failure"
	}
	rich = if response.status != Success Ok([]) else match response.value {
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
		Ok(data) => { status, result: response.result, stdout: response.stdout, diagnostics: response.diagnostics, data }
		Err(problem) => { status: "failure", result: response.result, stdout: response.stdout, diagnostics: if response.diagnostics.is_empty() problem else "${response.diagnostics}\n${problem}", data: [] }
	}
	Json.to_str(reply)
}
