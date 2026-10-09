module [decode, encode]

# One JSON object per line. Rejected requests are answered without evaluating
# code; syntax/type/runtime errors in Roc code are reported by encode.
decode : Str -> Try(Str, Str)
decode = |line| {
	request : Try({ code : Str }, [InvalidJson(Str), MissingRequiredField(Str)])
	request = Json.parse(line)
	match request {
		Ok({ code }) => Ok(code)
		Err(problem) => Err(encode({ result: "", stdout: "", diagnostics: Str.inspect(problem) }))
	}
}

encode : { result : Str, stdout : Str, diagnostics : Str } -> Str
encode = |response| Json.to_str(response)
