#!/usr/bin/env elixir

args = System.argv()
resumed? = "--resume" in args
answer = if(resumed?, do: "resumed answer", else: "first answer")

IO.puts(
  ~s({"type":"system","subtype":"init","session_id":"claude-fixture-session","model":"claude-fixture"})
)

IO.puts(
  ~s({"type":"assistant","session_id":"claude-fixture-session","message":{"model":"claude-fixture","stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":1},"content":[{"type":"thinking","thinking":"fixture thinking"},{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"true"}}]}})
)

IO.puts(
  ~s({"type":"user","session_id":"claude-fixture-session","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"tool complete","is_error":false}]}})
)

IO.puts(
  ~s({"type":"stream_event","session_id":"claude-fixture-session","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"#{answer}"}}})
)

IO.puts(
  ~s({"type":"assistant","session_id":"claude-fixture-session","message":{"model":"claude-fixture","stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":2},"content":[{"type":"text","text":"#{answer}"}]}})
)

IO.puts(
  ~s({"type":"result","subtype":"success","is_error":false,"result":"#{answer}","session_id":"claude-fixture-session","usage":{"input_tokens":3,"output_tokens":2}})
)
