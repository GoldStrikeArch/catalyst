# :release tests build and boot a real OTP release (minutes) — opt in with
# `mix test.release` (umbrella root) or `mix test --only release`.
ExUnit.start(exclude: [:release])
