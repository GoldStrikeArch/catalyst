await_extension_bootstrap = fn await_extension_bootstrap, attempts ->
  case :sys.get_state(Catalyst.Extensions) do
    %{bootstrap: :complete} ->
      :ok

    _not_ready when attempts > 0 ->
      receive do
      after
        10 -> await_extension_bootstrap.(await_extension_bootstrap, attempts - 1)
      end

    state ->
      raise "extension bootstrap did not complete before web tests: #{inspect(state)}"
  end
end

:ok = await_extension_bootstrap.(await_extension_bootstrap, 500)

ExUnit.start()

# Keep Codex-shaped UI models but send their turns through the offline Demo
# provider. Register through the same live seam used by runtime extensions.
codex_api = "openai-codex-responses"
{:ok, previous_codex_provider} = Catalyst.LLM.Registry.fetch_config(codex_api)

:ok =
  Catalyst.LLM.Registry.register_provider(
    codex_api,
    Catalyst.LLM.Demo
  )

ExUnit.after_suite(fn _results ->
  Catalyst.LLM.Registry.register_provider(codex_api, previous_codex_provider)
end)
