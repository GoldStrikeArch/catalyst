ExUnit.start()

# Keep Codex-shaped UI models but send their turns through the offline Demo
# provider. Register through the same live seam used by runtime extensions.
codex_api = "openai-codex-responses"
previous_codex_provider = Catalyst.LLM.Registry.fetch_config(codex_api)

:ok =
  Catalyst.LLM.Registry.register_provider(
    codex_api,
    Catalyst.LLM.Demo
  )

ExUnit.after_suite(fn _results ->
  Catalyst.LLM.Registry.register_provider(codex_api, previous_codex_provider)
end)
